@echo off
setlocal
echo ---------------------------------------------------------------
echo Rust: Starting .proto to grpc client stubs compilation ...
echo ---------------------------------------------------------------

rem %~dp0 is this script's own directory (with a trailing backslash), never the caller's CWD.
docker build --no-cache -t ondewo-rust-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: Rust: docker build failed 1>&2
    exit /b 1
)

echo ---------------------------------------------------------------
echo [OK] Rust: Done .proto to grpc client stubs compilation
echo ---------------------------------------------------------------
endlocal
