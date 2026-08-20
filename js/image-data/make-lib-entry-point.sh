#!/bin/bash

# -------------- Create pulbic-api.js from the commonjs output of the proto compilation step
# to pass a single file to webpack as an entry point

#Root directory of the compilation ( -> public api file in this directory + proto commonjs stubs are in this/api )
TEMP_SRC_DIRECTORY="$1"
#Location of the directory where the target api file will be put
#OUT_DIRECTORY=$2
DEFAULT_FILES_DIR=default-lib-files
FILE_EXT=".js"

#Can also be specified in provided directory -> no auto generation
PUBLIC_API_FILE="$TEMP_SRC_DIRECTORY/public-api$FILE_EXT"

#Exit on error
set -e

if [ ! -f "$PUBLIC_API_FILE" ]; then
    echo "No public-api$FILE_EXT specified in source directory -> copying default file"
    cp "$DEFAULT_FILES_DIR/public-api$FILE_EXT" "$PUBLIC_API_FILE"

    # Trying to auto generate public-api file
    cd "$TEMP_SRC_DIRECTORY"

    #ES6 Style exports
    export PREFIX="export * from '"
    export POSTFIX="';"

    #find api -iname "*.ts" -printf "$PREFIX%p$POSTFIX\n" >> $PUBLIC_API_FILE
    # explicit "." start path: BSD/macOS find has no GNU-style implicit path.
    # -path ./public-api* is pruned: this file is created (from the default) BEFORE the find
    # runs, so without the prune the webpack entry point star-exports ITSELF -- a circular
    # self-reference webpack resolves to nothing useful. find prints "./x", so the printf adds
    # no second "./" of its own or every specifier comes out as '././x'.
    find . -path "./public-api$FILE_EXT" -prune -o -iname "*$FILE_EXT" -exec bash -c 'printf "$PREFIX%s$POSTFIX\n" "${@%.*}"' _ {} + >> "$PUBLIC_API_FILE"
    # -i.bak (not bare -i) keeps this working with both GNU and BSD/macOS sed
    sed -i.bak '/\/node_modules\//d' "$PUBLIC_API_FILE"
    sed -i.bak '/\/webpack/d' "$PUBLIC_API_FILE"
    rm -f "$PUBLIC_API_FILE.bak"
fi
