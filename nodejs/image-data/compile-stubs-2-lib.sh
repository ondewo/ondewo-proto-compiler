#!/bin/bash
set -e

#Root directory of the compilation -> public api file + package.js
SRC_DIRECTORY=$1

# -------------- Start the angular build process
echo "Starting nodejs build process of library package ..."

#echo "Installing src package dependecies"
#cd $SRC_DIRECTORY
#npm install

#echo "Executing nodejs build'"
#tsc
#echo "Copying generated stubs lib to output"
mkdir -p "$SRC_DIRECTORY/lib"
mkdir -p "$SRC_DIRECTORY/lib/api"
cp -r "$SRC_DIRECTORY/api/"* "$SRC_DIRECTORY/lib/api"
cp "$SRC_DIRECTORY/package.json" "$SRC_DIRECTORY/lib/package.json"

#Copy all public api files
cd "$SRC_DIRECTORY" || exit 1
for f in "$SRC_DIRECTORY"/public-api*; do [ -e "$f" ] && cp "$f" "$SRC_DIRECTORY/lib"; done

cd "$SRC_DIRECTORY/lib" || exit 1
npm install


echo "Finished web build."
