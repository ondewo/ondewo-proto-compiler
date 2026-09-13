@echo off
setlocal
echo ---------------------------------------------------------------
echo Javascript: Starting .proto to grpc client stubs compilation ...
echo ---------------------------------------------------------------

docker build --no-cache -t ondewo-js-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: Javascript: docker build failed 1>&2
    exit /b 1
)

echo ---------------------------------------------------------------
echo [OK] Javascript: Done .proto to grpc client stubs compilation
echo ---------------------------------------------------------------
endlocal
