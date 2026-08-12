#!/bin/bash
set -e

# -------------- Create pulbic-api.ts from the commonjs output of the proto compilation step
# to pass a single file to webpack as an entry point

#Root directory of the compilation ( -> public api file in this directory + proto commonjs stubs are in this/api )
TEMP_SRC_DIRECTORY=$1

DEFAULT_FILES_DIR=default-lib-files
FILE_EXT=".ts"

#Can also be specified in provided directory -> no auto generation
PUBLIC_API_FILE=$TEMP_SRC_DIRECTORY/public-api$FILE_EXT

GENERATE_PUBLIC_API=$(cd "$(dirname "$0")" && pwd)/generate-public-api.sh

if [ ! -f "$PUBLIC_API_FILE" ]; then
  echo "No public-api$FILE_EXT specified in source directory -> copying default file"
  cp "$DEFAULT_FILES_DIR/public-api$FILE_EXT" "$PUBLIC_API_FILE"

  # Trying to auto generate public-api file
  bash "$GENERATE_PUBLIC_API" "$TEMP_SRC_DIRECTORY" "$PUBLIC_API_FILE"
fi
