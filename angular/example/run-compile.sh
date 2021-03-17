#Excute the example compilation (by runnning the image with mounting this directory in the image)
FILEDIRECTORY=$(pwd)/`dirname $0`

# -it flag for running in interactive mode (stdout/stdin) + mounting volume containing src files

# Consume protos and package.json from input volume and write library to output volume
if [ -z "$1" ]; then
    mkdir -p $FILEDIRECTORY/lib
    docker run -it -v $FILEDIRECTORY:/input-volume -v $FILEDIRECTORY/lib:/output-volume ondewo-angular-proto-compiler protos
else
    #Use bash inside container for debugging container and script issues
    docker run -it --entrypoint /bin/bash -v $FILEDIRECTORY:/input-volume -v $FILEDIRECTORY/lib:/output-volume ondewo-angular-proto-compiler
fi


# No ouput volume -> creates ouput directory "/lib" in mounted input volume
#docker run -it -v $FILEDIRECTORY:/input-volume ondewo-angular-proto-compiler

#Use bash inside container for debugging container and script issues
#docker run -it --entrypoint /bin/bash -v $FILEDIRECTORY:/input-volume -v $FILEDIRECTORY/lib:/output-volume ondewo-angular-proto-compiler