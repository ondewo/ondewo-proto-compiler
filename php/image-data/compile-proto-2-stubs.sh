#!/bin/bash
set -e

# -------------- Generate the PHP gRPC client stubs with a single protoc call
#
# Usage: compile-proto-2-stubs.sh <stubs_target_dir> <protos_root_dir> <protos_src_dir>
#   <stubs_target_dir>  directory the generated .php files are written to
#   <protos_root_dir>   protoc's -I root; proto import paths are resolved against it
#   <protos_src_dir>    the ENTRY set: every .proto below it is compiled, plus everything those
#                       protos transitively import (resolved below)
#
# One protoc call over the transitively resolved proto set - the same shape as the js target and
# deliberately NOT typescript's two-call "main protos + dependency file" split, which can hand
# protoc an empty file list ("Missing input file.").

STUBS_TARGET_DIR="$1"
PROTOS_ROOT_DIR="$2"
PROTOS_SRC_DIR="$3"

#Container default; env-overridable so this script can be driven on a host that has no plugin
#binary (the bats mock layer never execs it - protoc only ever receives its path as a flag).
GRPC_PHP_PLUGIN="${GRPC_PHP_PLUGIN:-/usr/bin/grpc_php_plugin}"

if [ -z "$STUBS_TARGET_DIR" ] || [ -z "$PROTOS_ROOT_DIR" ] || [ -z "$PROTOS_SRC_DIR" ]; then
    echo "usage: compile-proto-2-stubs.sh <stubs_target_dir> <protos_root_dir> <protos_src_dir>" >&2
    exit 1
fi

echo "Stubs target dir: $STUBS_TARGET_DIR"
echo "Protos root dir: $PROTOS_ROOT_DIR"
echo "Protos src dir: $PROTOS_SRC_DIR"

# -------------- Transitive .proto dependency resolution
#
# Carried over from js/image-data/dependecy-resolver.sh, inlined here because the file set of a
# compiler target is fixed. The `google/protobuf/` exclusion is LOAD-BEARING for PHP, not an
# optimisation: the well-known types already ship as classes inside the `google/protobuf` composer
# package, and regenerating them produces duplicate class declarations that fatal at autoload.
# The mirror image is just as load-bearing: non-well-known google protos (google/api/annotations,
# google/rpc/status, ...) MUST be generated, because a generated descriptor's initOnce() calls
# theirs and fatals without them. Do not "simplify" this away.

# BSD/macOS realpath has no --relative-to: canonicalise both paths with cd+pwd
# and strip the root prefix (resolved files are always under the proto root)
relativeToRoot() {
    _rtr_root=$(cd "$1" && pwd) || return 1
    _rtr_dir=$(cd "$(dirname "$2")" && pwd) || return 1
    _rtr_abs="$_rtr_dir/$(basename "$2")"
    printf '%s\n' "${_rtr_abs#"$_rtr_root"/}"
}

echoDependencies() {

    ROOT_DIR="$1"
    FILE_PATHS="$2"
    EXCLUDE_REGEX="$3"

    while IFS= read -r FILE_PATH; do

        if [ ! -f "$FILE_PATH" ]; then
            FILE_PATH="$ROOT_DIR/$FILE_PATH"
        fi

        #Everything reaching here has to be a readable regular file: relativeToRoot's `cd` and the
        #import scan's `sed` below both produce garbage (or nothing) for a directory. Their failure
        #CANNOT propagate on its own - this whole function runs inside the `if ! ALL_PROTO_FILES=$(...)`
        #below, and `set -e` is disabled for an if-condition - so an unchecked one silently ships a
        #short file list with rc 0. Both are therefore checked explicitly and abort the subshell,
        #which is the one construct the caller's `if !` does see.
        if [ ! -f "$FILE_PATH" ]; then
            echo "ERROR: '$FILE_PATH' is not a readable .proto file - exiting" >&2
            exit 1
        fi
        if ! RELATIVE=$(relativeToRoot "$ROOT_DIR" "$FILE_PATH"); then
            echo "ERROR: failed to resolve '$FILE_PATH' against the protos root '$ROOT_DIR' - exiting" >&2
            exit 1
        fi
        echo "$RELATIVE"

        # extract the quoted path of every `import "x/y.proto";` line
        # (portable sed instead of grep -P, which BSD/macOS grep lacks)
        IMPORT_PATHS=$(sed -n 's|.*import[[:space:]][[:space:]]*"\([a-zA-Z0-9./_-]*\)".*|\1|p' "$FILE_PATH")

        while IFS= read -r IMPORT_PATH; do

            ABS_PATH="$ROOT_DIR/$IMPORT_PATH"
            REL_PATH="$(dirname "$FILE_PATH")/$IMPORT_PATH"

            # `|| true`: grep exits 1 on "no match", which is the normal case here
            IS_EXCLUDED=""
            if [ -n "$EXCLUDE_REGEX" ]; then
                IS_EXCLUDED=$(printf '%s\n' "$IMPORT_PATH" | grep -E "$EXCLUDE_REGEX" || true)
            fi

            if [ -n "$IS_EXCLUDED" ]; then
                printf ""
            elif [ -f "$ABS_PATH" ]; then
                echoDependencies "$ROOT_DIR" "$ABS_PATH" "$EXCLUDE_REGEX"
            elif [ -f "$REL_PATH" ]; then
                echoDependencies "$ROOT_DIR" "$REL_PATH" "$EXCLUDE_REGEX"
            elif [ -n "$IMPORT_PATH" ]; then
                echo "$FILE_PATH --> Failed to resolve dependency with root: '$ROOT_DIR' and import path: '$IMPORT_PATH'" >&2
                exit 1
            fi

        done <<< "$IMPORT_PATHS"

    done <<< "$FILE_PATHS"
}

echoProtoDependencies() {
    echoDependencies "$1" "$2" "google/protobuf/"
}

# -------------- Find the entry .proto files and verify there are any
echo "Checking $PROTOS_SRC_DIR for .proto files"

if [ ! -d "$PROTOS_SRC_DIR" ]; then
    echo "ERROR: No proto files were found - the protos source directory '$PROTOS_SRC_DIR' does not exist - exiting" >&2
    exit 1
fi
# The `google/protobuf/` exclusion documented above has to be applied to the ENTRY set too, not
# just to the import closure: a protos root that vendors the well-known types (every
# ondewo-nlu-api checkout does) sweeps them in whenever no target subdirectory is given - which
# is what the example and `make run` do - and regenerating them fatals at autoload all the same.
#
# The filter stays NARROWER than java's `! -path "*/google/*"`, and the difference is visible in
# exactly one case: an UNSCOPED run over a vendored api tree. There the entry set is the only
# thing that can reach a google proto nothing imports, and php wants those generated - only
# google/protobuf ships as a composer package, so a vendored google/api or google/rpc has no
# other source. (For an imported google proto the entry filter is irrelevant either way: the
# resolver above adds it, and its exclusion is `google/protobuf/` too.)
#
# `-type f`, because a DIRECTORY named e.g. "vendor.proto" otherwise enters the set and makes the
# resolver's `cd`/`sed` fail on a garbage path. `!` (not `-not`) and an explicit start path, for
# GNU/BSD portability.
ENTRY_PROTO_FILES=$(find "$PROTOS_SRC_DIR" -type f -iname "*.proto" ! -path "*/google/protobuf/*")
if [ -z "$ENTRY_PROTO_FILES" ]; then
    echo "ERROR: No proto files were found in the '$PROTOS_SRC_DIR' directory, but are required to build a library from - exiting" >&2
    exit 1
fi
PROTO_FILES_CNT=$(printf '%s\n' "$ENTRY_PROTO_FILES" | grep -c . || true)
echo "Found $PROTO_FILES_CNT .proto files in directory: $PROTOS_SRC_DIR"
echo "Source verified."

# -------------- Resolve the entry set's transitive imports
if ! ALL_PROTO_FILES=$(echoProtoDependencies "$PROTOS_ROOT_DIR" "$ENTRY_PROTO_FILES"); then
    echo "ERROR: dependency resolution failed for the protos below '$PROTOS_SRC_DIR' - exiting" >&2
    exit 1
fi
ALL_PROTO_FILES=$(printf '%s\n' "$ALL_PROTO_FILES" | sort -u | tr "\n" " ")
ALL_PROTO_FILES_CNT=$(printf '%s\n' "$ALL_PROTO_FILES" | tr " " "\n" | grep -c . || true)

# -------------- Generate the proto client library stubs
echo "Starting .proto to grpc client stubs compilation ..."
echo "Consuming $ALL_PROTO_FILES_CNT .proto files (entry set + transitive imports, google/protobuf excluded):"
printf "%s\n\n" "$ALL_PROTO_FILES"

#Start from an EMPTY stub target, like every other target does with its own. The tree this writes
#into sits beside a verbatim copy of the input volume, so a client that keeps a `generated-src/`
#of its own (or the previous run's, when the output volume is nested in the input volume) would
#otherwise have it merged into the compiler-owned stubs by protoc and shipped as generated output.
#It also keeps the stub of a renamed/deleted proto from surviving into the new package. Guarded
#with :? so an empty variable can never turn this into `rm -rf /`.
rm -rf "${STUBS_TARGET_DIR:?}"
mkdir -p "$STUBS_TARGET_DIR"

#protoc is invoked from the proto root so the resolved, root-relative file names line up with -I.
#It is deliberately called UNQUALIFIED: the pinned /usr/local/bin/protoc has to win the PATH lookup
#over Debian's /usr/bin/protoc (dragged in by protobuf-compiler-grpc), and an absolute path would
#also defeat the PATH mock the test suite drives this script with.
cd "$PROTOS_ROOT_DIR" || { echo "ERROR: failed to enter the protos root directory '$PROTOS_ROOT_DIR' - exiting" >&2; exit 1; }

#--php_out is protoc built-in and takes no options here (messages, enums and the GPBMetadata
#descriptor bootstrap). The `Client` suffix on the service stubs comes from grpc_php_plugin, whose
#default class_suffix is kept; it would be overridable as --grpc_out=class_suffix=Stub:DIR.
#Passing --grpc_out for a service-less .proto is a no-op with rc 0, so no partitioning is needed.
# shellcheck disable=SC2086  # intentional word splitting of the resolved proto file list
protoc \
--php_out="$STUBS_TARGET_DIR" \
--grpc_out="$STUBS_TARGET_DIR" \
--plugin=protoc-gen-grpc="$GRPC_PHP_PLUGIN" \
-I "$PROTOS_ROOT_DIR" \
$ALL_PROTO_FILES

echo ".proto compilation finished."

# grep -c . (not wc -l): BSD/macOS wc pads its output with leading spaces, and `-type f` so a
# DIRECTORY named "*.php" cannot pass the "did protoc actually generate anything?" guard below.
STUB_FILES_CNT=$(find "$STUBS_TARGET_DIR" -type f -iname "*.php" | grep -c . || true)
echo "files generated by proto compilation: $STUB_FILES_CNT"

if [ "$STUB_FILES_CNT" -lt 1 ]; then
    echo "ERROR: protoc produced no .php files in '$STUBS_TARGET_DIR' - exiting" >&2
    exit 1
fi
