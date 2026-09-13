@echo off
setlocal
echo ---------------------------------------------------------------
echo Go: Starting .proto to grpc client stubs compilation ...
echo ---------------------------------------------------------------

docker build --no-cache -t ondewo-go-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: Go: docker build failed 1>&2
    exit /b 1
)

echo ---------------------------------------------------------------
echo [OK] Go: Done .proto to grpc client stubs compilation
echo ---------------------------------------------------------------
endlocal
