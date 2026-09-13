@echo off
setlocal
echo ---------------------------------------------------------------
echo Angular: Starting .proto to grpc client stubs compilation ...
echo ---------------------------------------------------------------

docker build --no-cache -t ondewo-angular-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: Angular: docker build failed 1>&2
    exit /b 1
)

echo ---------------------------------------------------------------
echo [OK] Angular: Done .proto to grpc client stubs compilation
echo ---------------------------------------------------------------
endlocal
