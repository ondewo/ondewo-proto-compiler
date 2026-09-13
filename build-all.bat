@echo off
setlocal enabledelayedexpansion
echo ##########################################################
echo Start building all ondewo-proto-compilers docker images ...
echo ##########################################################

set "SCRIPT_DIR=%~dp0"

for %%L in (python angular js nodejs typescript php go rust cpp java csharp) do (
    echo.
    echo ^>^>^> Building %%L ...
    if not exist "%SCRIPT_DIR%%%L" (
        echo ERROR: missing dir %%L 1>&2
        exit /b 1
    )
    call "%SCRIPT_DIR%%%L\build.bat"
    if errorlevel 1 (
        echo ERROR: %%L build FAILED 1>&2
        exit /b 1
    )
    echo ^>^>^> %%L build complete.
)

echo ##########################################################
echo [OK] Building all ondewo-proto-compilers docker images.
echo ##########################################################
endlocal
