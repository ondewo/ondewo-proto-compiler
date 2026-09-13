@echo off
setlocal
echo ---------------------------------------------------------------
echo PHP: Starting .proto to grpc client stubs compilation ...
echo ---------------------------------------------------------------

docker build --no-cache -t ondewo-php-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: PHP: docker build failed 1>&2
    exit /b 1
)

echo ---------------------------------------------------------------
echo [OK] PHP: Done .proto to grpc client stubs compilation
echo ---------------------------------------------------------------
endlocal
