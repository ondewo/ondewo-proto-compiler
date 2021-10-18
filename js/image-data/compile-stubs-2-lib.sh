#!/bin/bash

SRC_DIRECTORY="$1"
OUT_FILE_NAME="$2"
OUT_LIB_NAME="$3"

if [ -z "$OUT_LIB_NAME" ]; then
    OUT_LIB_NAME=OUT_FILE_NAME
fi

#Exit on error
set -e

# -------------- Start the webpack build process
echo "Starting webpack build process of library package ..."

CWD=$(pwd)

OUTPUT_DIR=./lib/
ENTRY_POINT_FILE=./public-api.js

cd "$SRC_DIRECTORY" || exit
npm install
node_modules/.bin/webpack --config ./webpack.dev.js --output-library "$OUT_FILE_NAME" --output-filename "$OUT_FILE_NAME.js" --output-path "$OUTPUT_DIR" --entry "$ENTRY_POINT_FILE"

cd "$CWD"

echo "Finished webpack build."

#cd $CALLWORKINGDIR
