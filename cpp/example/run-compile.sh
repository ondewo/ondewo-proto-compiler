#!/bin/sh
#Excute the example compilation (by runnning the image with mounting this directory in the image)
FILEDIRECTORY="$(cd "$(dirname "$0")" && pwd)"

# -it flag for running in interactive mode (stdout/stdin) + mounting volume containing src files
# NOTE: it is deliberately absent from the codegen invocation below - it breaks every
# non-interactive caller with "cannot attach stdin to a TTY-enabled container".

# Arguments: <relative_protos_dir> <target_subdir> <library_name>
# "." as the target subdir compiles every proto under the root; spelled as a dot rather than
# left empty so the library name cannot slide into the target-subdir position.

# Consume protos from the input volume and write the packaged library to the output volume
if [ -z "$1" ]; then
    mkdir -p "$FILEDIRECTORY/lib"
    docker run -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-cpp-proto-compiler protos . ondewo_example_client
else
    #Use bash inside container for debugging container and script issues
    docker run -it --entrypoint /bin/bash -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-cpp-proto-compiler
fi


# No ouput volume -> creates ouput directory "/lib" in mounted input volume
#docker run -v $FILEDIRECTORY:/input-volume ondewo-cpp-proto-compiler

#Use bash inside container for debugging container and script issues
#docker run -it --entrypoint /bin/bash -v $FILEDIRECTORY:/input-volume -v $FILEDIRECTORY/lib:/output-volume ondewo-cpp-proto-compiler
