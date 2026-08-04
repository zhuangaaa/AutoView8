@echo off
setlocal enabledelayedexpansion

set V8_VERSION=%1
set BUILD_ARGS=%2

echo ==========================================
echo Building v8dasm for Windows x64
echo V8 Version: %V8_VERSION%
echo Build Args: %BUILD_ARGS%
echo ==========================================

REM 检测运行环境 (GitHub Actions 或本地)
if "%GITHUB_WORKSPACE%"=="" (
    echo 检测到本地环境
    set WORKSPACE_DIR=%~dp0..\..
    set IS_LOCAL=true
    echo 本地环境，跳过依赖安装 (请确保已安装: git, python, Visual Studio/clang^)
) else (
    echo 检测到 GitHub Actions 环境
    set WORKSPACE_DIR=%GITHUB_WORKSPACE%
    set IS_LOCAL=false
)

echo 工作空间: %WORKSPACE_DIR%

REM 配置 Git
git config --global user.name "V8 Disassembler Builder"
git config --global user.email "v8dasm.builder@localhost"
git config --global core.autocrlf false
git config --global core.filemode false

REM Prefer USERPROFILE (HOMEPATH has no drive letter and breaks on Actions D: workspace)
if not "%USERPROFILE%"=="" (
  cd /d "%USERPROFILE%"
) else (
  cd /d "%HOMEDRIVE%%HOMEPATH%"
)

REM Keep a workspace-local copy path for artifact upload reliability
set WORK_V8_ROOT=%WORKSPACE_DIR%\v8
if not exist "%WORK_V8_ROOT%" mkdir "%WORK_V8_ROOT%"

REM 获取 Depot Tools
if not exist depot_tools (
    echo =====[ Getting Depot Tools ]=====
    powershell -command "Invoke-WebRequest https://storage.googleapis.com/chrome-infra/depot_tools.zip -O depot_tools.zip"
    powershell -command "Expand-Archive depot_tools.zip -DestinationPath depot_tools"
    del depot_tools.zip
)

set PATH=%CD%\depot_tools;%PATH%
set DEPOT_TOOLS_WIN_TOOLCHAIN=0
call gclient

REM Fetch/build under workspace\v8 so paths are stable on Actions
cd /d "%WORK_V8_ROOT%"

REM 获取 V8 源码
if not exist v8 (
    echo =====[ Fetching V8 ]=====
    call fetch v8
    echo target_os = ['win'] >> .gclient
)

cd v8
set V8_DIR=%CD%

REM Checkout 指定版本
echo =====[ Checking out V8 %V8_VERSION% ]=====
call git fetch --all --tags
call git checkout %V8_VERSION%
call gclient sync

REM Apply View8 patches via Python semantic rewriter (no git reset; tree is clean post-checkout)
echo =====[ Applying semantic V8 patches ]=====
set PATCH_LOG=%WORKSPACE_DIR%\scripts\v8dasm-builders\patch-utils\patch-state.log
set SEMANTIC_SCRIPT=%WORKSPACE_DIR%\scripts\v8dasm-builders\patch-utils\semantic-patches.py

where python >nul 2>&1
if errorlevel 1 (
  echo ERROR: python not found
  exit /b 1
)

echo Running: python "%SEMANTIC_SCRIPT%" "%V8_DIR%" "%PATCH_LOG%"
python "%SEMANTIC_SCRIPT%" "%V8_DIR%" "%PATCH_LOG%"
if errorlevel 1 (
  echo Patch application failed. See %PATCH_LOG%
  type "%PATCH_LOG%"
  exit /b 1
)

echo Patch applied successfully
if exist "%PATCH_LOG%" type "%PATCH_LOG%"


REM 配置构建（复制预置 args.gn，避免 cmd/引号问题）
echo =====[ Configuring V8 Build ]=====
if not exist out.gn\x64.release mkdir out.gn\x64.release
copy /Y "%WORKSPACE_DIR%\scripts\v8dasm-builders\args.win.gn" "out.gn\x64.release\args.gn"
if errorlevel 1 (
  echo ERROR: failed to copy args.win.gn
  exit /b 1
)

echo --- args.gn ---
type out.gn\x64.release\args.gn
echo ---------------

call gn gen out.gn\x64.release
if errorlevel 1 (
  echo ERROR: gn gen failed
  exit /b 1
)

REM 构建 V8 静态库
echo =====[ Building V8 Monolith ]=====
call ninja -C out.gn\x64.release v8_monolith
if errorlevel 1 (
  echo ERROR: ninja v8_monolith failed
  exit /b 1
)

REM 编译 v8dasm：先 clang-cl 出 obj，再用 lld-link（避免 MSVC link.exe 的 LNK1107）
echo =====[ Compiling v8dasm ]=====
set DASM_SOURCE=%WORKSPACE_DIR%\Disassembler\v8dasm.cpp
set OUTPUT_NAME=v8dasm-%V8_VERSION%.exe
set LLVM_BIN=%V8_DIR%\third_party\llvm-build\Release+Asserts\bin
set CLANG_CL=%LLVM_BIN%\clang-cl.exe
set LLD_LINK=%LLVM_BIN%\lld-link.exe

if not exist "%CLANG_CL%" (
  echo ERROR: clang-cl not found at %CLANG_CL%
  exit /b 1
)
if not exist "%LLD_LINK%" (
  echo ERROR: lld-link not found at %LLD_LINK%
  exit /b 1
)
if not exist "out.gn\x64.release\obj\v8_monolith.lib" (
  echo ERROR: missing out.gn\x64.release\obj\v8_monolith.lib
  exit /b 1
)

echo Using compiler: %CLANG_CL%
echo Using linker:   %LLD_LINK%
dir out.gn\x64.release\obj\v8_monolith.lib
dir out.gn\x64.release\obj\v8_libbase.lib
dir out.gn\x64.release\obj\v8_libplatform.lib

REM Must match V8 GN flags used for this Node bytecode build
"%CLANG_CL%" /nologo /c /O2 /std:c++20 /EHsc /MT /DUNICODE /D_UNICODE ^
  /DV8_COMPRESS_POINTERS /DV8_ENABLE_SANDBOX /DV8_31BIT_SMIS_ON_64BIT_ARCH ^
  /I. /Iinclude ^
  /Fo"v8dasm.obj" ^
  "%DASM_SOURCE%"
if errorlevel 1 (
  echo ERROR: clang-cl compile of v8dasm.cpp failed
  exit /b 1
)

REM Monolithic build: only v8_monolith.lib is required/reliable
"%LLD_LINK%" /NOLOGO /SUBSYSTEM:CONSOLE /OUT:"%OUTPUT_NAME%" ^
  v8dasm.obj ^
  out.gn\x64.release\obj\v8_monolith.lib ^
  winmm.lib dbghelp.lib advapi32.lib user32.lib shell32.lib ole32.lib ws2_32.lib
if errorlevel 1 (
  echo ERROR: lld-link of v8dasm failed
  exit /b 1
)

if exist "%OUTPUT_NAME%" (
    echo =====[ Build Successful ]=====
    dir "%OUTPUT_NAME%"
    echo Build output: %CD%\%OUTPUT_NAME%
) else (
    echo ERROR: %OUTPUT_NAME% not found!
    exit /b 1
)
