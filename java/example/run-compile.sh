#!/bin/sh
set -e
#Excute the example compilation (by runnning the image with mounting this directory in the image)
FILEDIRECTORY="$(cd "$(dirname "$0")" && pwd)"

# NO -it on the codegen invocation: it breaks every non-interactive caller with
# "cannot attach stdin to a TTY-enabled container because stdin is not a terminal".
# -it is kept only on the --entrypoint /bin/bash debug form below.

# Consume protos from the input volume and write the maven library to the output volume
if [ -z "$1" ]; then
    mkdir -p "$FILEDIRECTORY/lib"
    docker run -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-java-proto-compiler protos
else
    #Use bash inside container for debugging container and script issues
    docker run -it --entrypoint /bin/bash -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-java-proto-compiler
fi


# No ouput volume -> creates ouput directory "/lib" in mounted input volume
#docker run -v $FILEDIRECTORY:/input-volume ondewo-java-proto-compiler protos

# Scope the compilation to one sub-directory of the protos root (arg 2), and override the
# maven coordinates of the generated library (args 3-5):
#docker run -v $FILEDIRECTORY:/input-volume -v $FILEDIRECTORY/lib:/output-volume \
#  ondewo-java-proto-compiler protos library com.ondewo ondewo-proto-stubs-java 5.14.0
