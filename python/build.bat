@echo off
setlocal
echo ---------------------------------------------------------------
echo Python: Starting .proto to grpc client stubs compilation ...
echo ---------------------------------------------------------------

docker build --no-cache -t ondewo-python-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: Python: docker build failed 1>&2
    exit /b 1
)

echo ---------------------------------------------------------------
echo [OK] Python: Done .proto to grpc client stubs compilation
echo ---------------------------------------------------------------
endlocal
