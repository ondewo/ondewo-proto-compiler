@echo off
setlocal
rem Excute the example compilation (by runnning the image with mounting this directory in the image).
rem %~dp0 is this script's own directory and always ends in a backslash - strip it so the mount
rem sources below do not come out as "C:\path\\lib".
set "FILEDIRECTORY=%~dp0"
set "FILEDIRECTORY=%FILEDIRECTORY:~0,-1%"

rem Any argument switches to the interactive debug shell inside the container.
if not "%~1"=="" goto debug

rem Consume the protos (and, if present, a composer.json) from the input volume and write the
rem library - composer.json, composer.lock, src/ and vendor/ - to the output volume.
rem NOTE: no -it on the codegen run - it breaks every non-interactive caller.
if not exist "%FILEDIRECTORY%\lib" mkdir "%FILEDIRECTORY%\lib"
docker run -v "%FILEDIRECTORY%":/input-volume -v "%FILEDIRECTORY%\lib":/output-volume ondewo-php-proto-compiler protos
if errorlevel 1 (
    echo ERROR: PHP: docker run failed 1>&2
    exit /b 1
)
goto end

:debug
rem Use bash inside container for debugging container and script issues
docker run -it --entrypoint /bin/bash -v "%FILEDIRECTORY%":/input-volume -v "%FILEDIRECTORY%\lib":/output-volume ondewo-php-proto-compiler
if errorlevel 1 (
    echo ERROR: PHP: docker run failed 1>&2
    exit /b 1
)

:end
endlocal
