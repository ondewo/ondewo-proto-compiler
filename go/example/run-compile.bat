@echo off
setlocal
rem Excute the example compilation (by runnning the image with mounting this directory in the image)
set "FILEDIRECTORY=%~dp0"
rem %~dp0 always ends in a backslash - strip it, a trailing backslash mangles the -v mount
if "%FILEDIRECTORY:~-1%"=="\" set "FILEDIRECTORY=%FILEDIRECTORY:~0,-1%"

rem -v mounts the volume containing the src files (no -it: it breaks every non-interactive caller)

rem Arguments handed to the image:
rem   protos  -> the directory below the input volume that is protoc's -I root
rem   ""      -> no target sub-directory: test.proto imports dependency/myimport.proto, and a
rem              narrowed sub-directory has to be closed over every non-google import
rem   github.com/... -> the go module path; protoc-gen-go bakes it into every generated file

rem Consume protos from input volume and write library to output volume
if "%~1"=="" (
    if not exist "%FILEDIRECTORY%\lib" mkdir "%FILEDIRECTORY%\lib"
    docker run -v "%FILEDIRECTORY%":/input-volume -v "%FILEDIRECTORY%\lib":/output-volume ondewo-go-proto-compiler protos "" github.com/ondewo/ondewo-proto-compiler-go-example
    if errorlevel 1 (
        echo ERROR: Go: .proto to grpc client stubs compilation failed 1>&2
        exit /b 1
    )
) else (
    rem Use bash inside container for debugging container and script issues
    docker run -it --entrypoint /bin/bash -v "%FILEDIRECTORY%":/input-volume -v "%FILEDIRECTORY%\lib":/output-volume ondewo-go-proto-compiler
)
endlocal
