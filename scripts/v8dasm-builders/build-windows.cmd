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


REM 配置构建
echo =====[ Configuring V8 Build ]=====
REM 构建 GN 参数字符串
set GN_ARGS=target_os=\"win\" target_cpu=\"x64\" is_component_build=false is_debug=false use_custom_libcxx=false v8_monolithic=true v8_static_library=true v8_enable_disassembler=true v8_enable_object_print=true v8_use_external_startup_data=false dcheck_always_on=false symbol_level=0 is_clang=true

REM 如果有额外的构建参数，追加
if not "%BUILD_ARGS%"=="" (
    set GN_ARGS=%GN_ARGS% %BUILD_ARGS%
)

echo GN Args: %GN_ARGS%

REM 直接使用 gn gen 生成构建配置
call gn gen out.gn\x64.release --args="%GN_ARGS%"

REM 构建 V8 静态库
echo =====[ Building V8 Monolith ]=====
call ninja -C out.gn\x64.release v8_monolith

REM 编译 v8dasm
echo =====[ Compiling v8dasm ]=====
set DASM_SOURCE=%WORKSPACE_DIR%\Disassembler\v8dasm.cpp
set OUTPUT_NAME=v8dasm-%V8_VERSION%.exe

clang++ %DASM_SOURCE% ^
    -std=c++20 ^
    -O2 ^
    -Iinclude ^
    -Lout.gn\x64.release\obj ^
    -lv8_libbase ^
    -lv8_libplatform ^
    -lv8_monolith ^
    -o %OUTPUT_NAME%

REM 验证编译
if exist %OUTPUT_NAME% (
    echo =====[ Build Successful ]=====
    dir %OUTPUT_NAME%
    echo.
    echo ✅ 编译完成: %OUTPUT_NAME%
    echo    位置: %CD%\%OUTPUT_NAME%
) else (
    echo ERROR: %OUTPUT_NAME% not found!
    exit /b 1
)
