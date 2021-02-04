#echo "enter something"
#read my_var
#echo "You entered $my_var"

DEFAULTFILESDIR=default-lib-files

TEMPSRCDIRECTORY=/usr/src/app/src
PROTOSDIR=$TEMPSRCDIRECTORY/protos
PROTOTARGETDIR=$TEMPSRCDIRECTORY/api
#Mouted at root
INPUTVOLUMEFS=/input-volume
OUTPUTVOLUMEFS=/output-volume
CALLWORKINGDIR=$(pwd)

if [ -f $OUTPUTVOLUMEFS ]; then
    #Clean output volume if exists
    rm -r OUTPUTVOLUMEFS/*
fi


#INPUTVOLUMEFS=example

PROTOGENNG=./node_modules/.bin/protoc-gen-ng

#Copy source-volume contents to new directory (to not modify the original files during compilation)
#rm -r $TEMPSRCDIRECTORY
mkdir -p $TEMPSRCDIRECTORY
cp -r $INPUTVOLUMEFS/* $TEMPSRCDIRECTORY

# -------------- Check if all the requirements are there and exist if not
echo "Checking if all the source requirements are fulfilled ..."
TSCONFIGFILE=$TEMPSRCDIRECTORY/tsconfig.json
if [ ! -f $TSCONFIGFILE ]; then
    echo "No tsconfig.json specified in source directory -> copying default file"
    cp $DEFAULTFILESDIR/tsconfig.json $TSCONFIGFILE
fi

NGPACKAGEFILE=$TEMPSRCDIRECTORY/ng-package.json
if [ ! -f $NGPACKAGEFILE ]; then
    echo "No ng-package.json specified in source directory -> copying default file"
    cp $DEFAULTFILESDIR/ng-package.json $NGPACKAGEFILE
fi

PACKAGEFILE=$TEMPSRCDIRECTORY/package.json
if [ ! -f $PACKAGEFILE ]; then
    echo "ERROR: A package.json file was not specified in the mounted directory this is however required - exitting"
    exit 1
fi

#Find .protos in directory and count the occurances
echo "Checking $PROTOSDIR for .proto files"
PROTOFILESCNT=$(tree $PROTOSDIR | fgrep .proto | wc -l)
if [[ $PROTOFILESCNT -lt 1 ]]; then
    echo "ERROR: No proto files were found in the '/protos' directory, but are required to build a library from - exitting"
    exit 1
fi
echo "Found $PROTOFILESCNT .proto files in directory: $PROTOSDIR"
echo "Source verified."

# -------------- Generate the proto client library stubs
echo "Starting .proto to grpc client stubs compilation ..."
PROTOFILES=$(find $PROTOSDIR -iname "*.proto")
echo "Consuming .proto files: $PROTOFILES: "

mkdir -p $PROTOTARGETDIR
protoc \
--plugin=$PROTOGENNG \
--ng_out=service=grpc-node:$PROTOTARGETDIR \
-I $PROTOSDIR \
$PROTOFILES

#protoc --plugin=/usr/src/app/node_modules/@ngx-grpc/protoc-gen-ts --ts-out=service=grpc-node:/usr/src/app/out -I /usr/src/app/protos /usr/src/app/protos/test.proto
echo ".proto compilation finished"

# -------------- Create pulbic-api.ts from the typescript output of the proto compilation step

PUBLICAPIFILE=$TEMPSRCDIRECTORY/public-api.ts
if [ ! -f $PUBLICAPIFILE ]; then
    echo "No public-api.ts specified in source directory -> copying default file"
    cp $DEFAULTFILESDIR/public-api.ts $PUBLICAPIFILE

    # Trying to auto generate public-api file
    cd $TEMPSRCDIRECTORY

    export PREFIX="export * from '"
    export POSTFIX="';"

    #find api -iname "*.ts" -printf "$PREFIX%p$POSTFIX\n" >> $PUBLICAPIFILE
    find api -iname "*.ts" -exec bash -c 'printf "$PREFIX./%s$POSTFIX\n" "${@%.*}"' _ {} + >> $PUBLICAPIFILE
fi


# -------------- Start the angular build process
echo "Starting angular build process of library package ..."

cd $TEMPSRCDIRECTORY
npm install
ng build
echo "Finished angular build."
cd $CALLWORKINGDIR

# -------------- Copy results back to mounted directory

if [ ! -f $OUTPUTVOLUMEFS ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUTVOLUMEFS=$INPUTVOLUMEFS/lib
    mkdir -p $OUTPUTVOLUMEFS
fi

echo "Copying output files to mounted directory"
#mkdir -p $INPUTVOLUMEFS/lib
cp -r $TEMPSRCDIRECTORY/lib/* $OUTPUTVOLUMEFS
echo "Finished copying"

# -------------- END
echo ".proto to angular libary compilation finished successfully and ouput files are located in 'lib' directory of the mounted volume"