@echo off
setlocal

rem Execute the example compilation by running the image with this directory mounted.
rem %~dp0 is this script's own directory (with a trailing backslash), never the caller's CWD.
rem
rem NOTE: this example deliberately ships NO Cargo.toml, so the image falls back to its default
rem crate manifest (crate name "ondewo-proto-stubs"). A real client MUST mount its own
rem Cargo.toml: a crate name is the consumer-facing import path, so every client relying on
rem the default would publish - and collide on - the same crate.

if not exist "%~dp0lib" mkdir "%~dp0lib"

rem Entrypoint args: <relative_protos_dir> [<target_subdir>]. No -it on the codegen run:
rem a TTY-enabled container breaks every non-interactive caller.
if "%~1"=="" (
    docker run -v "%~dp0.":/input-volume -v "%~dp0lib":/output-volume ondewo-rust-proto-compiler protos
) else (
    rem Use bash inside container for debugging container and script issues
    docker run -it --entrypoint /bin/bash -v "%~dp0.":/input-volume -v "%~dp0lib":/output-volume ondewo-rust-proto-compiler
)
if errorlevel 1 (
    echo ERROR: Rust: docker run failed 1>&2
    exit /b 1
)

endlocal
