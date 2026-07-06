#!/bin/bash

# BSD/macOS realpath has no --relative-to: canonicalise both paths with cd+pwd
# and strip the root prefix (resolved files are always under the proto root)
relativeToRoot(){
    _rtr_root=$(cd "$1" && pwd) || return 1
    _rtr_dir=$(cd "$(dirname "$2")" && pwd) || return 1
    _rtr_abs="$_rtr_dir/$(basename "$2")"
    printf '%s\n' "${_rtr_abs#"$_rtr_root"/}"
}

echoDependencies(){

    ROOT_DIR="$1"
    FILE_PATHS="$2"
    EXCLUDE_REGEX="$3"

    #echo "ROOT_DIR: $ROOT_DIR"
    #echo "FILE_PATHS: $FILE_PATHS"

    while IFS= read -r FILE_PATH; do
        #echo "Consuming: $FILE_PATH"

        if [ ! -f "$FILE_PATH" ]; then
            FILE_PATH="$ROOT_DIR/$FILE_PATH"
        fi
        RELATIVE=$(relativeToRoot "$ROOT_DIR" "$FILE_PATH")
        echo "$RELATIVE"

        #echo "Print dependencies for $FILE_PATH"

        # extract the quoted path of every `import "x/y.proto";` line
        # (portable sed instead of grep -P, which BSD/macOS grep lacks)
        IMPORT_PATHS=$(sed -n 's|.*import[[:space:]][[:space:]]*"\([a-zA-Z0-9./_-]*\)".*|\1|p' "$FILE_PATH")
        #echo "$FILE_PATH --> IMPORT_PATHS: $IMPORT_PATHS"

        while IFS= read -r IMPORT_PATH; do

            #echo "$FILE_PATH --> Resolving: '$IMPORT_PATH'"

            ABS_PATH="$ROOT_DIR/$IMPORT_PATH"
            REL_PATH="$(dirname "$FILE_PATH")/$IMPORT_PATH"
            #echo "ABS_PATH: $ABS_PATH"
            #echo "REL_PATH: $REL_PATH"

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
                echo "$FILE_PATH --> Failed to resolve dependency with root: '$ROOT_DIR' and import path: '$IMPORT_PATH'" >&2
                exit 1
            fi

        done <<< "$IMPORT_PATHS"

    done <<< "$FILE_PATHS"
}

echoProtoDependencies(){
    echoDependencies "$1" "$2" "google/protobuf/"
}

#echoProtoDependencies "$1" "$2"
