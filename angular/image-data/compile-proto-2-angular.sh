#!/bin/bash

#Root path of all the protos to be compiled

echo "HELLLLLOOOOO"

RELATIVE_PROTOS_DIR=$1
if [ -z "$1" ]; then
    RELATIVE_PROTOS_DIR="protos"
fi
echo "$RELATIVE_PROTOS_DIR"

IMAGE_DATA_DIRECTORY=/image-data
DEFAULT_FILES_DIR=$IMAGE_DATA_DIRECTORY/default-lib-files

#Input volumes mouted at root
INPUT_VOLUME_FS=/input-volume
OUTPUT_VOLUME_FS=/output-volume

TEMP_SRC_DIRECTORY=$IMAGE_DATA_DIRECTORY/src
#Copy source-volume contents to new directory (to not modify the original files during compilation)
cp -r $INPUT_VOLUME_FS $TEMP_SRC_DIRECTORY

PROTOS_ROOT_PATH=$INPUT_VOLUME_FS/$RELATIVE_PROTOS_DIR

#If not specified take all protos in the protos root path (otherwise a relative directory)
#Subdir of the protos to be compiled
COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/$2
if [ -z "$2" ]; then
    COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/
fi
echo "$COMPILE_SELECTED_PROTOS_DIR"

#Clean output volume if exists
echo "Clean output volume (remove everything except src-folder and dot prefixed files/dirs)"
CURRENT_DIR=$(pwd)
shopt -s extglob # needed to allow pattern matching on rm
cd $OUTPUT_VOLUME_FS
# rm -r !(".*"|"src")
rm -r bundles
rm -r esm2015
rm -r fesm2015
rm -r node_modules
rm -r npm
rm -r src/node_modules
rm -r ondewo-vtsi-client-angular.d.ts
rm -r ondewo-vtsi-client-angular.metadata.json
rm -r ondewo-vtsi-client-angular.d.ts.map
rm -r package.json
rm -r public-api.d.ts
cd $CURRENT_DIR

#Create lib dir for output if no output specified
if [ ! -d $OUTPUT_VOLUME_FS ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUT_VOLUME_FS=$INPUT_VOLUME_FS/lib
    mkdir -p $OUTPUT_VOLUME_FS
fi

# -------------- Check if all the requirements are there and exist if not
echo "Checking if all the source requirements are fulfilled ..."

if [ ! -f $TEMP_SRC_DIRECTORY/package.json ]; then
    echo "ERROR: A package.json file was not specified in the mounted directory this is however required - exitting"
    exit 1
fi

if [ ! -f $TEMP_SRC_DIRECTORY/README.md ]; then
    echo "ERROR: A README.md file (for NPM) was not specified in the mounted directory this is however required - exitting"
    exit 1
fi

if [ ! -f $TEMP_SRC_DIRECTORY/.github/README.md ]; then
    echo "ERROR: A README.md file (for GitHub) was not specified in the mounted directory this is however required - exitting"
    exit 1
fi

if [ ! -f $TEMP_SRC_DIRECTORY/RELEASE.md ]; then
    echo "ERROR: A RELEASE.md file (for GitHub) was not specified in the mounted directory this is however required - exitting"
    exit 1
fi

if [ ! -f $TEMP_SRC_DIRECTORY/LICENSE ]; then
    echo "No LICENSE file specified in source directory -> copying default file"
    cp $DEFAULT_FILES_DIR/LICENSE $TEMP_SRC_DIRECTORY/LICENSE
fi

if [ ! -f $TEMP_SRC_DIRECTORY/tsconfig.json ]; then
    echo "No tsconfig.json specified in source directory -> copying default file"
    cp $DEFAULT_FILES_DIR/tsconfig.json $TEMP_SRC_DIRECTORY/tsconfig.json
fi

if [ ! -f $TEMP_SRC_DIRECTORY/ng-package.json ]; then
    echo "No ng-package.json specified in source directory -> copying default file"
    cp $DEFAULT_FILES_DIR/ng-package.json $TEMP_SRC_DIRECTORY/ng-package.json
fi

# TEMP_LIB_DIRECTORY=$IMAGE_DATA_DIRECTORY/lib

# -------------- Running compilation steps
echo "START: Executing \"compile-proto-2-stubs.sh\"..."
bash ./compile-proto-2-stubs.sh $TEMP_SRC_DIRECTORY/api $PROTOS_ROOT_PATH $COMPILE_SELECTED_PROTOS_DIR
echo "DONE: Executing \"compile-proto-2-stubs.sh\"..."
echo "START: Executing \"make-lib-entry-point.sh\"..."
bash ./make-lib-entry-point.sh $TEMP_SRC_DIRECTORY
echo "DONE: Executing \"make-lib-entry-point.sh\"..."
echo "START: Executing \"compile-stubs-2-lib.sh\"..."
bash ./compile-stubs-2-lib.sh $IMAGE_DATA_DIRECTORY $TEMP_SRC_DIRECTORY
echo "DONE: Executing \"compile-stubs-2-lib.sh\"..."

# -------------- Copy results back to mounted directory

echo "Copying output files to mounted directory"
cp -r $TEMP_SRC_DIRECTORY/lib/* $OUTPUT_VOLUME_FS
echo "Finished copying"

# -------------- Copy GitHub README and RELEASE
# echo "Copying GitHub README $TEMP_SRC_DIRECTORY/RELEASE.md and RELEASE files"
# cp -r $TEMP_SRC_DIRECTORY/.github $OUTPUT_VOLUME_FS
# cp $TEMP_SRC_DIRECTORY/RELEASE.md $OUTPUT_VOLUME_FS
# cat $TEMP_SRC_DIRECTORY/RELEASE.md
# echo "Finished copying"

# -------------- Creating NPM folder
echo "Copying files for NPM publish to NPM folder"
rm -rf $OUTPUT_VOLUME_FS/npm
mkdir $OUTPUT_VOLUME_FS/npm
cp -r $TEMP_SRC_DIRECTORY/lib/* $OUTPUT_VOLUME_FS/npm
echo "Finished copying"

# -------------- END
echo
echo ".proto to angular library compilation finished successfully."
echo "Files are located in given output directory."
echo
echo "Also a npm-folder for publishing to NPM was created."
echo "For publishing on NPM run: 'npm publish npm --access public' from output directory or run the publish-npm script."
echo "(Check if versions in package.json and RELEASE.md are correct)"
