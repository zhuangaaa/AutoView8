@echo off
REM apply-patch.cmd - Apply View8/v8dasm patches to a checked-out V8 tree.
REM Prefer semantic patches (version-tolerant). Fall back to git apply.
REM
REM Usage: apply-patch.cmd <patch_file> <v8_dir> <log_file> [abort_on_failure]

setlocal enabledelayedexpansion

set PATCH_FILE=%~1
set V8_DIR=%~2
set LOG_FILE=%~3
set ABORT_ON_FAILURE=%~4
if "%ABORT_ON_FAILURE%"=="" set ABORT_ON_FAILURE=true

if "%PATCH_FILE%"=="" goto :usage
if "%V8_DIR%"=="" goto :usage
if "%LOG_FILE%"=="" goto :usage
if not exist "%PATCH_FILE%" (
  echo ERROR: patch file missing: %PATCH_FILE%
  exit /b 1
)
if not exist "%V8_DIR%" (
  echo ERROR: V8 dir missing: %V8_DIR%
  exit /b 1
)

for %%F in ("%LOG_FILE%") do set LOG_DIR=%%~dpF
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

echo =====[ V8 Patch Application ]===== > "%LOG_FILE%"
echo Patch: %PATCH_FILE%>> "%LOG_FILE%"
echo V8: %V8_DIR%>> "%LOG_FILE%"
echo Time: %date% %time%>> "%LOG_FILE%"
echo.>> "%LOG_FILE%"

echo =====[ V8 Patch Application ]=====
echo Patch: %PATCH_FILE%
echo V8: %V8_DIR%

cd /d "%V8_DIR%"
git reset --hard HEAD >> "%LOG_FILE%" 2>&1
git clean -fd >> "%LOG_FILE%" 2>&1

REM --- Level 1: semantic patches (best for cross-version) ---
set SCRIPT_DIR=%~dp0
set SEMANTIC_SCRIPT=%SCRIPT_DIR%semantic-patches.py
set PYTHON_CMD=
where python >nul 2>&1 && set PYTHON_CMD=python
if "%PYTHON_CMD%"=="" (
  where python3 >nul 2>&1 && set PYTHON_CMD=python3
)
if "%PYTHON_CMD%"=="" (
  echo ERROR: Python not found
  echo ERROR: Python not found>> "%LOG_FILE%"
  goto :fail
)

echo [1] Running semantic-patches.py ...
echo [1] Running semantic-patches.py ...>> "%LOG_FILE%"
%PYTHON_CMD% "%SEMANTIC_SCRIPT%" "%V8_DIR%" "%LOG_FILE%"
if errorlevel 1 (
  echo [1] semantic patches failed
  echo [1] semantic patches failed>> "%LOG_FILE%"
) else (
  echo [1] semantic patches OK
  echo [1] semantic patches OK>> "%LOG_FILE%"
  exit /b 0
)

REM --- Level 2: git apply -3 ---
echo [2] Trying git apply -3 ...
echo [2] Trying git apply -3 ...>> "%LOG_FILE%"
cd /d "%V8_DIR%"
git reset --hard HEAD >> "%LOG_FILE%" 2>&1
git apply -3 --verbose "%PATCH_FILE%" >> "%LOG_FILE%" 2>&1
if errorlevel 1 (
  echo [2] git apply -3 failed
  echo [2] git apply -3 failed>> "%LOG_FILE%"
  goto :fail
)

echo [2] git apply -3 OK
echo [2] git apply -3 OK>> "%LOG_FILE%"
exit /b 0

:fail
echo.
echo FAILED: could not apply V8 patches
echo See log: %LOG_FILE%
echo FAILED: could not apply V8 patches>> "%LOG_FILE%"
if /i "%ABORT_ON_FAILURE%"=="true" exit /b 1
exit /b 0

:usage
echo Usage: %~nx0 ^<patch_file^> ^<v8_dir^> ^<log_file^> [abort_on_failure]
exit /b 1
