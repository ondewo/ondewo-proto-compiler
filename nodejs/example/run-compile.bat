@echo off
setlocal
rem Execute the example compilation (by running the image with this directory mounted into it)
set "FILEDIRECTORY=%~dp0"

rem Consume protos and package.json from the input volume and write the library to the output volume.
rem Pass any argument to drop into a shell inside the container for debugging instead.
if "%~1"=="" (
    if not exist "%FILEDIRECTORY%lib" mkdir "%FILEDIRECTORY%lib"
    docker run -v "%FILEDIRECTORY%.":/input-volume -v "%FILEDIRECTORY%lib":/output-volume ondewo-nodejs-proto-compiler protos library
) else (
    rem Use bash inside the container for debugging container and script issues
    docker run -it --entrypoint /bin/bash -v "%FILEDIRECTORY%.":/input-volume -v "%FILEDIRECTORY%lib":/output-volume ondewo-nodejs-proto-compiler
)
if errorlevel 1 (
    echo ERROR: nodejs example compilation failed 1>&2
    exit /b 1
)
endlocal
