@echo off
setlocal
echo ---------------------------------------------------------------
echo Node.js: Starting .proto to grpc client stubs compilation ...
echo ---------------------------------------------------------------

docker build --no-cache -t ondewo-nodejs-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: Node.js: docker build failed 1>&2
    exit /b 1
)

echo ---------------------------------------------------------------
echo [OK] Node.js: Done .proto to grpc client stubs compilation
echo ---------------------------------------------------------------
endlocal
