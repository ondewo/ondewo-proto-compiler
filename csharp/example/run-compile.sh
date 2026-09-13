#!/bin/sh
set -e
#Excute the example compilation (by runnning the image with mounting this directory in the image)
FILEDIRECTORY="$(cd "$(dirname "$0")" && pwd)"

# Consume the protos from the input volume and write the C# library to the output volume.
# Arguments: <relative_protos_dir> <target_subdir> <package_id>
#   * the example protos sit directly in protos/, so the target sub-directory is the empty
#     string -> every .proto below the root is compiled. It must stay quoted, otherwise the
#     package id would shift into its place.
#   * NO -it on the codegen invocation: it breaks every non-interactive caller
#     ("cannot attach stdin to a TTY-enabled container because stdin is not a terminal").

if [ -z "$1" ]; then
    mkdir -p "$FILEDIRECTORY/lib"
    docker run -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-csharp-proto-compiler protos "" Ondewo.Example.Client
else
    #Use bash inside container for debugging container and script issues
    docker run -it --entrypoint /bin/bash -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-csharp-proto-compiler
fi


# No ouput volume -> creates ouput directory "/lib" in mounted input volume
#docker run -v $FILEDIRECTORY:/input-volume ondewo-csharp-proto-compiler
