
LIB_ENTRY_NAME=$1
if [ -z "$1" ]; then
    LIB_ENTRY_NAME=output_lib_name
fi


IMAGE_DATA_DIRECTORY=/image-data

DEFAULT_FILES_DIR=$IMAGE_DATA_DIRECTORY/default-lib-files

TEMP_SRC_DIRECTORY=/temp_src

#Input volumes mouted at root
INPUT_VOLUME_FS=/input-volume
OUTPUT_VOLUME_FS=/output-volume
#CALLWORKINGDIR=$(pwd)

#Clean output volume if exists
if [ ! -f $OUTPUT_VOLUME_FS ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUT_VOLUME_FS=$INPUT_VOLUME_FS/lib
    mkdir -p $OUTPUT_VOLUME_FS
fi
rm -r $OUTPUT_VOLUME_FS/*

#Copy source-volume contents to new directory (to not modify the original files during compilation)
#rm -r $TEMP_SRC_DIRECTORY
mkdir -p $TEMP_SRC_DIRECTORY
cp -r $INPUT_VOLUME_FS/* $TEMP_SRC_DIRECTORY

# -------------- Check if all the requirements are there and exist if not
echo "Checking if all the source requirements are fulfilled ..."

if [ ! -f $TEMP_SRC_DIRECTORY/webpack.js ]; then
    echo "No webpack.js specified in source directory -> copying default files"
    cp $DEFAULT_FILES_DIR/webpack.js $TEMP_SRC_DIRECTORY/webpack.js
    cp $DEFAULT_FILES_DIR/webpack.common.js $TEMP_SRC_DIRECTORY/webpack.common.js
    cp $DEFAULT_FILES_DIR/webpack.dev.js $TEMP_SRC_DIRECTORY/webpack.dev.js
fi

if [ ! -f $TEMP_SRC_DIRECTORY/package.json ]; then
    echo "No package.json specified in source directory -> copying default file"
    cp $DEFAULT_FILES_DIR/package.json $TEMP_SRC_DIRECTORY/package.json
fi

# -------------- Running compilation steps

bash ./compile-proto-2-stubs.sh $TEMP_SRC_DIRECTORY/protos $TEMP_SRC_DIRECTORY/api

bash ./make-lib-entry-point.sh $TEMP_SRC_DIRECTORY

cd $TEMP_SRC_DIRECTORY
npm install
webpack --config ./webpack.js --output-library $LIB_ENTRY_NAME --output-filename $LIB_ENTRY_NAME.js --output-path ./lib/ --entry ./public-api.js
#npm install
#npm run build

#bash ./compile-stubs-2-lib.sh $TEMP_SRC_DIRECTORY/public-api.js $TEMP_SRC_DIRECTORY/lib/library.js


# -------------- Copy results back to mounted directory

echo "Copying output files to mounted directory"
#mkdir -p $INPUTVOLUMEFS/lib
cp -r $TEMP_SRC_DIRECTORY/lib/* $OUTPUT_VOLUME_FS
echo "Finished copying"

# -------------- END
echo ".proto to js libary compilation finished successfully and ouput files are located in 'lib' directory of the mounted volume."