@echo off
setlocal
echo ---------------------------------------------------------------
echo Java: Starting .proto to grpc client stubs compilation ...
echo ---------------------------------------------------------------

docker build --no-cache -t ondewo-java-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: Java: docker build failed 1>&2
    exit /b 1
)

echo ---------------------------------------------------------------
echo [OK] Java: Done .proto to grpc client stubs compilation
echo ---------------------------------------------------------------
endlocal
