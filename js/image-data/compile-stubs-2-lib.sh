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
pwd

CWD=$(pwd)

OUTPUT_DIR=./lib/
ENTRY_POINT_FILE=./public-api.js

cd "$SRC_DIRECTORY" || exit
npm install

ls -l

echo "---------------------------------------------"
echo "public-api.js"
echo "---------------------------------------------"
ls -l $ENTRY_POINT_FILE
cat $ENTRY_POINT_FILE
echo "---------------------------------------------"

echo "---------------------------------------------"
echo "$WEBPACK_CONFIG"
echo "---------------------------------------------"
ls -l $WEBPACK_CONFIG
cat $WEBPACK_CONFIG
echo "---------------------------------------------"

# install webpack-cli again here locally
npm install -D webpack-cli --yes
ls -l node_modules/.bin/

node_modules/.bin/webpack --config "$WEBPACK_CONFIG" --output-library "$OUT_LIB_NAME" --output-filename "$OUT_FILE_NAME.js" --output-path "$OUTPUT_DIR" --entry "$ENTRY_POINT_FILE"

cd "$CWD"

echo "Finished webpack build."

#cd $CALLWORKINGDIR
