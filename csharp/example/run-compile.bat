@echo off
setlocal
rem Excute the example compilation (by runnning the image with mounting this directory in the image)
rem %~dp0 always ends with a backslash; strip it so the -v mount does not end in one.
set "FILEDIRECTORY=%~dp0"
set "FILEDIRECTORY=%FILEDIRECTORY:~0,-1%"

rem Consume the protos from the input volume and write the C# library to the output volume.
rem Arguments: <relative_protos_dir> <target_subdir> <package_id>
rem   * the example protos sit directly in protos\, so the target sub-directory is the empty
rem     string -> every .proto below the root is compiled. It must stay quoted, otherwise the
rem     package id would shift into its place.
rem   * NO -it on the codegen invocation: it breaks every non-interactive caller.

if not exist "%FILEDIRECTORY%\lib" mkdir "%FILEDIRECTORY%\lib"

docker run -v "%FILEDIRECTORY%":/input-volume -v "%FILEDIRECTORY%\lib":/output-volume ondewo-csharp-proto-compiler protos "" Ondewo.Example.Client
if errorlevel 1 (
    echo ERROR: C#: docker run failed 1>&2
    exit /b 1
)
endlocal
