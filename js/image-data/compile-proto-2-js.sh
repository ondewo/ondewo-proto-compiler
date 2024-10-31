#!/bin/bash


LIB_ENTRY_NAME=$(echo "$1" | sed -e 's/\-/\_/g')
if [ -z "$1" ]; then
    LIB_ENTRY_NAME=output_lib_name
fi

#Root path of all the protos to be compiled
RELATIVE_PROTOS_DIR="$2"
if [ -z "$2" ]; then
    RELATIVE_PROTOS_DIR="protos"
fi

IMAGE_DATA_DIRECTORY=/image-data
DEFAULT_FILES_DIR="$IMAGE_DATA_DIRECTORY/default-lib-files"
TEMP_SRC_DIRECTORY=/temp_src

#Input volumes mouted at root
INPUT_VOLUME_FS=/input-volume
OUTPUT_VOLUME_FS=/output-volume

PROTOS_ROOT_PATH="$INPUT_VOLUME_FS/$RELATIVE_PROTOS_DIR"

#Exit on error
set -e

#If not specified take all protos in the protos root path (otherwise a relative directory)
#Subdir of the protos to be compiled
COMPILE_SELECTED_PROTOS_DIR="$PROTOS_ROOT_PATH/$3"
if [ -z "$3" ]; then
    COMPILE_SELECTED_PROTOS_DIR="$PROTOS_ROOT_PATH"
fi

#Clean output volume if exists
if [ ! -d $OUTPUT_VOLUME_FS ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUT_VOLUME_FS="$INPUT_VOLUME_FS/lib"
    mkdir -p "$OUTPUT_VOLUME_FS"
fi
#rm -r $OUTPUT_VOLUME_FS/*

#Copy source-volume contents to new directory (to not modify the original files during compilation)
mkdir -p "$TEMP_SRC_DIRECTORY"
cp -r "$INPUT_VOLUME_FS"/* "$TEMP_SRC_DIRECTORY"

# -------------- Check if all the requirements are there and exist if not
echo "Checking if all the source requirements are fulfilled ..."

ls -l $DEFAULT_FILES_DIR
ls -l $TEMP_SRC_DIRECTORY

if [ ! -f $TEMP_SRC_DIRECTORY/webpack.js ]; then
    echo "No webpack.js specified in source directory -> copying default files"
    cp "$DEFAULT_FILES_DIR/webpack.js" "$TEMP_SRC_DIRECTORY/webpack.js"
    cp "$DEFAULT_FILES_DIR/webpack.common.js" "$TEMP_SRC_DIRECTORY/webpack.common.js"
    cp "$DEFAULT_FILES_DIR/webpack.dev.js" "$TEMP_SRC_DIRECTORY/webpack.dev.js"
fi

if [ ! -f "$TEMP_SRC_DIRECTORY/package.json" ]; then
    echo "No package.json specified in source directory -> copying default file"
    cp "$DEFAULT_FILES_DIR/package.json" "$TEMP_SRC_DIRECTORY/package.json"
fi

# -------------- Running compilation steps

bash ./compile-proto-2-stubs.sh "$TEMP_SRC_DIRECTORY" "$PROTOS_ROOT_PATH" "$COMPILE_SELECTED_PROTOS_DIR"
bash ./generate-client-wrappers.sh "$TEMP_SRC_DIRECTORY/$3"
bash ./make-lib-entry-point.sh "$TEMP_SRC_DIRECTORY"

bash ./compile-stubs-2-lib.sh "$TEMP_SRC_DIRECTORY" "$LIB_ENTRY_NAME.min" "webpack.js" "$LIB_ENTRY_NAME"
bash ./compile-stubs-2-lib.sh "$TEMP_SRC_DIRECTORY" "$LIB_ENTRY_NAME" "webpack.dev.js"

# -------------- Copy results back to mounted directory

echo "Copying output files to mounted directory"
#mkdir -p $INPUTVOLUMEFS/lib
cp -r "$TEMP_SRC_DIRECTORY/lib"/* "$OUTPUT_VOLUME_FS"
echo "Finished copying"

# -------------- END
echo ".proto to js libary compilation finished successfully and ouput files are located in 'lib' directory of the mounted volume."
