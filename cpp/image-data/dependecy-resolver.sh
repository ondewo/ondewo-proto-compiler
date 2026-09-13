#!/bin/bash

# BSD/macOS realpath has no --relative-to: canonicalise both paths with cd+pwd
# and strip the root prefix (resolved files are always under one of the roots).
# $1 is a SPACE-SEPARATED list of include roots, most specific FIRST: a proto that
# lives under an extra include dir must be spelled relative to THAT dir
# (google/api/annotations.proto), because that is the -I protoc resolves the
# import line against. Spelling it relative to the proto root instead
# (googleapis/google/api/annotations.proto) hands protoc the same file under two
# different names and it aborts. With a single root this is the plain prefix
# strip it always was.
relativeToRoot(){
    _rtr_dir=$(cd "$(dirname "$2")" && pwd) || return 1
    _rtr_abs="$_rtr_dir/$(basename "$2")"
    # under no root at all the absolute path is echoed back unchanged, exactly as
    # the plain prefix strip used to: protoc then rejects it by name ("File does
    # not reside within any path specified using --proto_path") instead of this
    # function inventing a spelling that resolves to a different file
    _rtr_rel="$_rtr_abs"
    # shellcheck disable=SC2086  # intentional word splitting of the include-root list
    for _rtr_root in $1; do
        _rtr_root_abs=$(cd "$_rtr_root" && pwd) || return 1
        case "$_rtr_abs" in
            "$_rtr_root_abs"/*) _rtr_rel="${_rtr_abs#"$_rtr_root_abs"/}"; break ;;
        esac
    done
    printf '%s\n' "$_rtr_rel"
}

echoDependencies(){

    ROOT_DIR="$1"
    FILE_PATHS="$2"
    EXCLUDE_REGEX="$3"
    # Optional space-separated list of ADDITIONAL include roots (absolute), for proto
    # trees that do not carry every import under the proto root - see the
    # EXTRA_PROTO_DIRS block in compile-proto-2-stubs.sh. Searched after the proto
    # root when an import does not resolve under it, and consulted BEFORE it when a
    # resolved file is spelled back out, so protoc is handed each file relative to
    # the very -I that resolves its import line.
    EXTRA_ROOT_DIRS="$4"
    SEARCH_ROOTS="$EXTRA_ROOT_DIRS $ROOT_DIR"

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
        RELATIVE=$(relativeToRoot "$SEARCH_ROOTS" "$FILE_PATH")
        echo "$RELATIVE"

        #echo "Print dependencies for $FILE_PATH"

        # extract the quoted path of every `import "x/y.proto";` line
        # (portable sed instead of grep -P, which BSD/macOS grep lacks)
        IMPORT_PATHS=$(sed -n 's|.*import[[:space:]][[:space:]]*"\([a-zA-Z0-9./_-]*\)".*|\1|p' "$FILE_PATH")
        #echo "$FILE_PATH --> IMPORT_PATHS: $IMPORT_PATHS"

        while IFS= read -r IMPORT_PATH; do

            #echo "$FILE_PATH --> Resolving: '$IMPORT_PATH'"

            ABS_PATH="$ROOT_DIR/$IMPORT_PATH"
            # An import that does not resolve under the proto root may still resolve
            # under one of the extra include roots (protoc is handed a -I for each of
            # them, searched in this same order). No extra roots => this loop has
            # nothing to iterate and the resolution below is unchanged.
            # shellcheck disable=SC2086  # intentional word splitting of the include-root list
            for EXTRA_ROOT_DIR in $EXTRA_ROOT_DIRS; do
                if [ ! -f "$ABS_PATH" ] && [ -f "$EXTRA_ROOT_DIR/$IMPORT_PATH" ]; then
                    ABS_PATH="$EXTRA_ROOT_DIR/$IMPORT_PATH"
                fi
            done
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

                echoDependencies "$ROOT_DIR" "$ABS_PATH" "$EXCLUDE_REGEX" "$EXTRA_ROOT_DIRS"
            elif [ -f "$REL_PATH" ]; then
                #echo "$REL_PATH"
                #RELATIVE=$(realpath --relative-to="$ROOT_DIR" "$REL_PATH")
                #echo "$RELATIVE"
                echoDependencies "$ROOT_DIR" "$REL_PATH" "$EXCLUDE_REGEX" "$EXTRA_ROOT_DIRS"
            elif [ -n "$IMPORT_PATH" ]; then
                echo "$FILE_PATH --> Failed to resolve dependency with root: '$ROOT_DIR'${EXTRA_ROOT_DIRS:+ (extra include roots:$EXTRA_ROOT_DIRS)} and import path: '$IMPORT_PATH'" >&2
                exit 1
            fi

        done <<< "$IMPORT_PATHS"

    done <<< "$FILE_PATHS"
}

# $3 (optional): space-separated extra include roots, see echoDependencies
echoProtoDependencies(){
    echoDependencies "$1" "$2" "google/protobuf/" "$3"
}

#echoProtoDependencies "$1" "$2"
