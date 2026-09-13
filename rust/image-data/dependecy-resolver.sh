#!/bin/bash

# BSD/macOS realpath has no --relative-to: canonicalise both paths with cd+pwd
# and strip the root prefix (resolved files are always under the proto root)
#
# $3 is the optional, space-separated list of EXTRA protoc include directories (absolute,
# already canonicalised by the caller). A file that lives under one of them is spelled
# relative to THAT directory, not to the proto root: the extra include dirs are nested
# inside the root (<root>/googleapis/google/api/x.proto), so the root-relative spelling
# and the spelling its importers use ("google/api/x.proto") are two different virtual
# paths for one file - handing protoc both makes it compile the file twice and collide
# on every symbol it declares. Extra dirs are deeper than the root, so the shortest
# candidate is always the most specific include directory containing the file.
relativeToRoot(){
    _rtr_root=$(cd "$1" && pwd) || return 1
    _rtr_dir=$(cd "$(dirname "$2")" && pwd) || return 1
    _rtr_abs="$_rtr_dir/$(basename "$2")"
    _rtr_best="${_rtr_abs#"$_rtr_root"/}"
    # an unchanged candidate means the prefix did not strip, i.e. the file is not under
    # that include dir
    for _rtr_extra in $3; do
        _rtr_candidate="${_rtr_abs#"$_rtr_extra"/}"
        if [ "$_rtr_candidate" != "$_rtr_abs" ] && [ "${#_rtr_candidate}" -lt "${#_rtr_best}" ]; then
            _rtr_best="$_rtr_candidate"
        fi
    done
    printf '%s\n' "$_rtr_best"
}

echoDependencies(){

    ROOT_DIR="$1"
    FILE_PATHS="$2"
    EXCLUDE_REGEX="$3"
    EXTRA_DIRS="$4"

    #echo "ROOT_DIR: $ROOT_DIR"
    #echo "FILE_PATHS: $FILE_PATHS"

    while IFS= read -r FILE_PATH; do
        #echo "Consuming: $FILE_PATH"

        if [ ! -f "$FILE_PATH" ]; then
            FILE_PATH="$ROOT_DIR/$FILE_PATH"
        fi
        # Still not a readable file => the caller's list was mangled, most often by a
        # proto whose NAME contains a newline, which `while read` splits into two bogus
        # fragments. Fail loudly: the alternative is silently dropping the real proto,
        # compiling the fragment and exiting 0 with an incomplete library. `exit` (not
        # `return`) is the one construct the caller's `if ! VAR=$(...)` can observe.
        if [ ! -f "$FILE_PATH" ]; then
            echo "ERROR: '$FILE_PATH' is not a readable .proto file - exiting" >&2
            exit 1
        fi
        RELATIVE=$(relativeToRoot "$ROOT_DIR" "$FILE_PATH" "$EXTRA_DIRS")
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

            # An import that does not resolve against the proto root may still resolve
            # against one of the EXTRA include dirs - that is the whole point of them
            # (ondewo-survey-api spells its google protos googleapis/google/..., so
            # `import "google/api/annotations.proto";` is only findable under
            # <root>/googleapis). Tried in the order given, before the
            # relative-to-the-importing-file fallback, exactly as protoc walks its -I list.
            EXTRA_PATH=""
            for EXTRA_DIR in $EXTRA_DIRS; do
                if [ -f "$EXTRA_DIR/$IMPORT_PATH" ]; then
                    EXTRA_PATH="$EXTRA_DIR/$IMPORT_PATH"
                    break
                fi
            done

            # An EMPTY regex must exclude NOTHING. Testing it first rather than
            # blanking the result afterwards matters: `grep -E ""` matches every
            # line, so running the grep first and then clearing the result leaves
            # a branch that can only be reached by a caller that does not exist
            # (echoProtoDependencies always passes "google/protobuf/").
            IS_EXCLUDED=""
            if [ -n "$EXCLUDE_REGEX" ]; then
                IS_EXCLUDED=$(echo "$IMPORT_PATH" | grep -E "$EXCLUDE_REGEX")
            fi

            if [ -n "$IS_EXCLUDED" ]; then
                #echo "EXCLUDE: $IMPORT_PATH"
                #echo "MATCH: $IS_EXCLUDED"
                printf ""
            elif [ -f "$ABS_PATH" ]; then
                #echo "$ABS_PATH"
                #RELATIVE=$(realpath --relative-to="$ROOT_DIR" "$ABS_PATH")
                #echo "$RELATIVE"

                echoDependencies "$ROOT_DIR" "$ABS_PATH" "$EXCLUDE_REGEX" "$EXTRA_DIRS"
            elif [ -n "$EXTRA_PATH" ]; then
                echoDependencies "$ROOT_DIR" "$EXTRA_PATH" "$EXCLUDE_REGEX" "$EXTRA_DIRS"
            elif [ -f "$REL_PATH" ]; then
                #echo "$REL_PATH"
                #RELATIVE=$(realpath --relative-to="$ROOT_DIR" "$REL_PATH")
                #echo "$RELATIVE"
                echoDependencies "$ROOT_DIR" "$REL_PATH" "$EXCLUDE_REGEX" "$EXTRA_DIRS"
            elif [ -n "$IMPORT_PATH" ]; then
                echo "$FILE_PATH --> Failed to resolve dependency with root: '$ROOT_DIR' and import path: '$IMPORT_PATH'" >&2
                exit 1
            fi

        done <<< "$IMPORT_PATHS"

    done <<< "$FILE_PATHS"
}

echoProtoDependencies(){
    echoDependencies "$1" "$2" "google/protobuf/" "$3"
}

#echoProtoDependencies "$1" "$2"
