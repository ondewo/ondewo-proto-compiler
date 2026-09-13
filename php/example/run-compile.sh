#!/bin/sh
set -e
#Excute the example compilation (by runnning the image with mounting this directory in the image)
FILEDIRECTORY="$(cd "$(dirname "$0")" && pwd)"

# -it flag for running in interactive mode (stdout/stdin) + mounting volume containing src files
# NOTE: the codegen run below must NEVER carry -it - it breaks every non-interactive caller with
# "cannot attach stdin to a TTY-enabled container". -it belongs on the debug branch only.

# Consume the protos (and, if present, a composer.json) from the input volume and write the
# library - composer.json, composer.lock, src/ and vendor/ - to the output volume.
# Args: <relative_protos_dir> [<target_subdir>]; no target subdir here, so every .proto below
# protos/ is compiled, which is what pulls dependency/myimport.proto in as well.
if [ -z "$1" ]; then
    mkdir -p "$FILEDIRECTORY/lib"
    docker run -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-php-proto-compiler protos
else
    #Use bash inside container for debugging container and script issues
    docker run -it --entrypoint /bin/bash -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-php-proto-compiler
fi


# No ouput volume -> creates ouput directory "/lib" in mounted input volume
#docker run -v $FILEDIRECTORY:/input-volume ondewo-php-proto-compiler protos
