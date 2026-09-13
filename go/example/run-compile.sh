#!/bin/sh
set -e
#Excute the example compilation (by runnning the image with mounting this directory in the image)
FILEDIRECTORY="$(cd "$(dirname "$0")" && pwd)"

# -v mounts the volume containing the src files (no -it: it breaks every non-interactive caller)

# Arguments handed to the image:
#   protos  -> the directory below the input volume that is protoc's -I root
#   ""      -> no target sub-directory: test.proto imports dependency/myimport.proto, and a
#              narrowed sub-directory has to be closed over every non-google import (protoc-gen-go
#              emits a go import for a dependency proto even when the import is unused)
#   github.com/... -> the go module path; protoc-gen-go bakes it into every generated file, so it
#              has to be known before protoc runs

# Consume protos from input volume and write library to output volume
if [ -z "$1" ]; then
    mkdir -p "$FILEDIRECTORY/lib"
    docker run -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-go-proto-compiler protos "" github.com/ondewo/ondewo-proto-compiler-go-example
else
    #Use bash inside container for debugging container and script issues
    docker run -it --entrypoint /bin/bash -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-go-proto-compiler
fi
