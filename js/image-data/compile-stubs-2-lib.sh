#!/bin/bash

SRC_DIRECTORY="$1"
OUT_FILE_NAME="$2"
WEBPACK_CONFIG="$3"
OUT_LIB_NAME="$4"


if [ -z "$OUT_LIB_NAME" ]; then
    OUT_LIB_NAME="$OUT_FILE_NAME"
fi

if [ -z "$OUT_LIB_NAME" ]; then
    WEBPACK_CONFIG=webpack.js
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
node_modules/.bin/webpack --config "$WEBPACK_CONFIG" --output-library "$OUT_LIB_NAME" --output-filename "$OUT_FILE_NAME.js" --output-path "$OUTPUT_DIR" --entry "$ENTRY_POINT_FILE"

cd "$CWD"

echo "Finished webpack build."

#cd $CALLWORKINGDIR
