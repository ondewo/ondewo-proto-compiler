@echo off
setlocal
echo ---------------------------------------------------------------
echo Typescript: Starting .proto to grpc client stubs compilation ...
echo ---------------------------------------------------------------

docker build --no-cache -t ondewo-typescript-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: Typescript: docker build failed 1>&2
    exit /b 1
)

echo ---------------------------------------------------------------
echo [OK] Typescript: Done .proto to grpc client stubs compilation
echo ---------------------------------------------------------------
endlocal
