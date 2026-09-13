@echo off
setlocal
rem Excute the example compilation (by runnning the image with mounting this directory in the image)
rem %~dp0 is this script's own directory (with a trailing backslash), never the caller's CWD.
set "FILEDIRECTORY=%~dp0."

rem Arguments: <relative_protos_dir> <target_subdir> <library_name>
rem "." as the target subdir compiles every proto under the root.
rem NO -it on the codegen invocation - it breaks every non-interactive caller.

if not exist "%FILEDIRECTORY%\lib" mkdir "%FILEDIRECTORY%\lib"

docker run -v "%FILEDIRECTORY%":/input-volume -v "%FILEDIRECTORY%\lib":/output-volume ondewo-cpp-proto-compiler protos . ondewo_example_client
if errorlevel 1 (
    echo ERROR: C++: docker run failed 1>&2
    exit /b 1
)

echo ---------------------------------------------------------------
echo [OK] C++: Example .proto to grpc client stubs compilation done
echo ---------------------------------------------------------------

rem Use bash inside the container for debugging container and script issues:
rem docker run -it --entrypoint /bin/bash -v "%FILEDIRECTORY%":/input-volume -v "%FILEDIRECTORY%\lib":/output-volume ondewo-cpp-proto-compiler
endlocal
