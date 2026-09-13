@echo off
setlocal
echo ---------------------------------------------------------------
echo C++: Starting .proto to grpc client stubs compilation ...
echo ---------------------------------------------------------------

docker build --no-cache -t ondewo-cpp-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: C++: docker build failed 1>&2
    exit /b 1
)

echo ---------------------------------------------------------------
echo [OK] C++: Done .proto to grpc client stubs compilation
echo ---------------------------------------------------------------
endlocal
