@echo off
setlocal
rem Execute the example compilation (by running the image with this directory mounted into it)
set "FILEDIRECTORY=%~dp0"
echo %FILEDIRECTORY%

rem Consume protos and package.json from the input volume and write the library to the output volume
if not exist "%FILEDIRECTORY%lib" mkdir "%FILEDIRECTORY%lib"
docker run -v "%FILEDIRECTORY%.":/input-volume -v "%FILEDIRECTORY%lib":/output-volume ondewo-js-proto-compiler myfancylibrary
if errorlevel 1 (
    echo ERROR: js example compilation failed 1>&2
    exit /b 1
)
endlocal
