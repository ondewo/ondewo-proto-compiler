#!/bin/bash

ENTRY_POINT_FILE="$1"
COMPILED_LIB_FILE="$2"

IMAGE_DATA_DIRECTORY=/image-data

#Exit on error
set -e

# -------------- Start the webpack build process
echo "Starting webpack build process of library package ..."

#cd $TEMPSRCDIRECTORY

# -> Should consume proto output from $TEMPSRCDIRECTORY/api
webpack --config $IMAGE_DATA_DIRECTORY/webpack.prod.js  --entry "$ENTRY_POINT_FILE" --output-path "$COMPILED_LIB_FILE"
# -> should have placed output files of the webbpack build into $TEMPSRCDIRECTORY/lib

echo "Finished webpack build."

#cd $CALLWORKINGDIR
