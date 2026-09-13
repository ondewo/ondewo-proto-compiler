@echo off
setlocal

REM Excute the example compilation (by runnning the image with mounting this directory in the image)
REM %~dp0 is this script's own directory, so the example works from any CWD. The for/%%~fI
REM round trip normalises it to a fully-qualified path without the trailing "\." component.
for %%I in ("%~dp0.") do set "FILEDIRECTORY=%%~fI"

REM NO -it on the codegen invocation: it breaks every non-interactive caller with
REM "cannot attach stdin to a TTY-enabled container because stdin is not a terminal".
REM -it is kept only on the --entrypoint /bin/bash debug form below.

if not "%~1"=="" goto debug

if not exist "%FILEDIRECTORY%\lib" mkdir "%FILEDIRECTORY%\lib"
docker run -v "%FILEDIRECTORY%":/input-volume -v "%FILEDIRECTORY%\lib":/output-volume ondewo-java-proto-compiler protos
if errorlevel 1 (
    echo ERROR: Java: docker run failed 1>&2
    exit /b 1
)
goto end

:debug
REM Use bash inside container for debugging container and script issues
docker run -it --entrypoint /bin/bash -v "%FILEDIRECTORY%":/input-volume -v "%FILEDIRECTORY%\lib":/output-volume ondewo-java-proto-compiler
if errorlevel 1 (
    echo ERROR: Java: docker run failed 1>&2
    exit /b 1
)

:end
endlocal
