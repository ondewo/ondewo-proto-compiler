#!/bin/bash

echoDependencies(){

    ROOT_DIR="$1"
    FILE_PATH="$2"
    EXCLUDE_REGEX="$3"

    if [ ! -f "$FILE_PATH" ]; then
        FILE_PATH="$ROOT_DIR/$FILE_PATH"
    fi
    RELATIVE=$(realpath --relative-to="$ROOT_DIR" "$FILE_PATH")
    echo "$RELATIVE"

    #echo "Print dependencies for $FILE_PATH"

    #-E, --extended-regexp
    IMPORT_LINES=$(cat "$FILE_PATH" | grep -E -o "import[ ]+\"[a-zA-Z0-9\./_-]+\"")
    #echo "$FILE_PATH --> IMPORT_LINES: $IMPORT_LINES"
    #echo $IMPORT_LINES
    #-P, --perl-regexp  --  -o, --only-matching
    IMPORT_PATHS=$(echo "$IMPORT_LINES" | grep -o -P "(?<=\")[a-zA-Z0-9\./_-]+(?=\")")
    #echo "$FILE_PATH --> IMPORT_PATHS: $IMPORT_PATHS"

    while IFS= read -r IMPORT_PATH; do

        #echo "$FILE_PATH --> Resolving: '$IMPORT_PATH'"

        ABS_PATH="$ROOT_DIR/$IMPORT_PATH"
        REL_PATH="$(dirname "$FILE_PATH")/$IMPORT_PATH"

        IS_EXCLUDED=$(echo "$IMPORT_PATH" | grep -E "$EXCLUDE_REGEX")
        if [ -z "$EXCLUDE_REGEX" ]; then
            IS_EXCLUDED=""
        fi
        
        if [ -n "$IS_EXCLUDED" ]; then
            #echo "EXCLUDE: $IMPORT_PATH"
            #echo "MATCH: $IS_EXCLUDED"
            printf ""
        elif [ -f "$ABS_PATH" ]; then
            #echo "$ABS_PATH"
            #RELATIVE=$(realpath --relative-to="$ROOT_DIR" "$ABS_PATH")
            #echo "$RELATIVE"
            
            echoDependencies "$ROOT_DIR" "$ABS_PATH" "$EXCLUDE_REGEX"
        elif [ -f "$REL_PATH" ]; then
            #echo "$REL_PATH"
            #RELATIVE=$(realpath --relative-to="$ROOT_DIR" "$REL_PATH")
            #echo "$RELATIVE"
            echoDependencies "$ROOT_DIR" "$REL_PATH" "$EXCLUDE_REGEX"
        elif [ -n "$IMPORT_PATH" ]; then
            echo "$FILE_PATH --> Failed to resolve dependency with root: '$ROOT_DIR' and import path: '$IMPORT_PATH'"
            exit 1
        fi

    done <<< $IMPORT_PATHS
}

echoProtoDependencies(){
    echoDependencies "$1" "$2" "google/protobuf/"
}

#echoProtoDependencies "$1" "$2"



