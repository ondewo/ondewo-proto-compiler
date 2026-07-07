#!/bin/bash
set -e

#Root directory of the compilation -> public api file + package.js
SRC_DIRECTORY=$1

# -------------- Start the angular build process
echo "Starting typescript build process of library package ..."

#echo "Installing src package dependecies"
#cd $SRC_DIRECTORY
#npm install

#echo "Executing typescript build'"
#tsc
#echo "Copying generated stubs lib to output"
mkdir -p "$SRC_DIRECTORY/lib"
mkdir -p "$SRC_DIRECTORY/lib/api"
cp -r "$SRC_DIRECTORY"/api/* "$SRC_DIRECTORY/lib/api"
cp "$SRC_DIRECTORY/package.json" "$SRC_DIRECTORY/lib/package.json"

#Copy all public api files
cd "$SRC_DIRECTORY" || exit 1
for pub_api in public-api*; do
    if [ -e "$pub_api" ]; then
        cp "$pub_api" "$SRC_DIRECTORY/lib"
    fi
done

cd "$SRC_DIRECTORY/lib" || exit 1
npm install


echo "Finished web build."
