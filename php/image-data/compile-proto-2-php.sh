#!/bin/bash
set -e

# -------------- Orchestrator: .proto -> PHP gRPC client library (the image ENTRYPOINT)
#
# Usage: compile-proto-2-php.sh [<relative_protos_dir>] [<target_subdir>]
#   <relative_protos_dir>  path of the proto root INSIDE the input volume (default "protos").
#                          It becomes protoc's -I root, so proto import paths are resolved
#                          against it. For an ondewo client this is `ondewo-nlu-api`.
#   <target_subdir>        optional sub-directory of the proto root to scope generation to
#                          (default: the whole root). For an ondewo client this is `ondewo`,
#                          which keeps the google/ tree out of the ENTRY set while the
#                          dependency resolver still pulls in the non-well-known google protos
#                          that are actually imported.

#Root path of all the protos to be compiled
RELATIVE_PROTOS_DIR=$1
if [ -z "$1" ]; then
    RELATIVE_PROTOS_DIR="protos"
fi

#Container defaults; env-overridable so the script can run (and be tested) outside the image
IMAGE_DATA_DIRECTORY="${IMAGE_DATA_DIRECTORY:-/image-data}"
DEFAULT_FILES_DIR=$IMAGE_DATA_DIRECTORY/default-lib-files

#Input volumes mounted at root
INPUT_VOLUME_FS="${INPUT_VOLUME_FS:-/input-volume}"
OUTPUT_VOLUME_FS="${OUTPUT_VOLUME_FS:-/output-volume}"

TEMP_SRC_DIRECTORY="${TEMP_SRC_DIRECTORY:-$IMAGE_DATA_DIRECTORY/src}"

# -------------- Check if all the requirements are there and exit if not
echo "Checking if all the source requirements are fulfilled ..."

if [ ! -d "$INPUT_VOLUME_FS" ]; then
    echo "ERROR: the input volume '$INPUT_VOLUME_FS' does not exist - mount the directory holding the .proto files at /input-volume - exiting" >&2
    exit 1
fi

#The default manifest is both the library manifest fallback AND the file the image pre-warmed its
#offline composer cache from - if it is gone, the offline package build later cannot work either.
if [ ! -f "$DEFAULT_FILES_DIR/composer.json" ]; then
    echo "ERROR: the default library manifest '$DEFAULT_FILES_DIR/composer.json' is missing from the image - exiting" >&2
    exit 1
fi

#Copy source-volume contents to new directory (to not modify the original files during compilation)
mkdir -p "$TEMP_SRC_DIRECTORY"
cp -r "$INPUT_VOLUME_FS"/* "$TEMP_SRC_DIRECTORY" || { echo "ERROR: failed to copy the contents of the input volume '$INPUT_VOLUME_FS' - is it empty? - exiting" >&2; exit 1; }

PROTOS_ROOT_PATH=$INPUT_VOLUME_FS/$RELATIVE_PROTOS_DIR

#If not specified take all protos in the protos root path (otherwise a relative directory)
#Subdir of the protos to be compiled
COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/$2
if [ -z "$2" ]; then
    COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/
fi

#Clean output volume if exists
if [ ! -d "$OUTPUT_VOLUME_FS" ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUT_VOLUME_FS=$INPUT_VOLUME_FS/lib
    mkdir -p "$OUTPUT_VOLUME_FS"
fi

echo "Source verified."

# -------------- Running compilation steps
#Every step is failure-checked explicitly so a broken stage names itself instead of failing as a
#bare non-zero exit of the entrypoint.
#
#The generated stubs are staged in "generated-src", NOT in "src": the whole input volume was just
#copied into $TEMP_SRC_DIRECTORY above, and "src/" is THE conventional PHP source directory (PSR-4),
#so a client that keeps hand-written PHP there would have it silently merged into the compiler-owned
#generated tree and shipped as generated output. The staged package still publishes the stubs as
#lib/src, so the shipped layout (and composer.json's classmap ["src/"]) is unchanged.
bash ./compile-proto-2-stubs.sh "$TEMP_SRC_DIRECTORY/generated-src" "$PROTOS_ROOT_PATH" "$COMPILE_SELECTED_PROTOS_DIR" || { echo "ERROR: compile-proto-2-stubs.sh failed" >&2; exit 1; }
bash ./make-lib-entry-point.sh "$TEMP_SRC_DIRECTORY" "$DEFAULT_FILES_DIR" || { echo "ERROR: make-lib-entry-point.sh failed" >&2; exit 1; }
bash ./compile-stubs-2-lib.sh "$TEMP_SRC_DIRECTORY" || { echo "ERROR: compile-stubs-2-lib.sh failed" >&2; exit 1; }

# -------------- Copy results back to mounted directory

echo "Copying output files to mounted directory"
#Remove the previously generated output before copying the fresh one: `cp -r` MERGES rather than
#replaces, so without this a renamed/deleted proto would leave an orphaned stub behind, and a
#dependency set changed by an image rebuild would leave a dead vendor tree mixed into the new one.
#src/ and vendor/ are the two compiler-owned directories; composer.json / composer.lock are
#overwritten in place by the copy, and the client's hand-written auth/ is never touched.
if [ -n "$OUTPUT_VOLUME_FS" ] && [ -d "$OUTPUT_VOLUME_FS" ]; then
    rm -rf "${OUTPUT_VOLUME_FS:?}/src" "${OUTPUT_VOLUME_FS:?}/vendor"
fi
cp -r "$TEMP_SRC_DIRECTORY"/lib/* "$OUTPUT_VOLUME_FS" || { echo "ERROR: failed to copy the library to the output volume '$OUTPUT_VOLUME_FS'" >&2; exit 1; }
echo "Finished copying"

# -------------- Register the client's hand-written PHP with the shipped autoloader
#src/ is compiler-owned and wiped on every run, so hand-written client sources live in auth/ at the
#output-volume root - identical to the documented nodejs/typescript contract. PHP has no compile
#step, so "exporting" them just means making them reachable: add auth/ to the shipped classmap and
#rebuild the optimized autoloader. Idempotent - jq's `unique` keeps a second run from duplicating
#the entry - and a client without auth/ is left completely untouched.
if [ -d "$OUTPUT_VOLUME_FS/auth" ] && [ -f "$OUTPUT_VOLUME_FS/composer.json" ]; then
    echo "Found hand-written sources in '$OUTPUT_VOLUME_FS/auth' -> adding them to the library autoloader"
    AUTH_MANIFEST_TMP=$(mktemp "${TMPDIR:-/tmp}/composer-auth.XXXXXX")
    jq '.autoload = ((.autoload // {}) | .classmap = (((.classmap // []) + ["auth/"]) | unique))' \
        "$OUTPUT_VOLUME_FS/composer.json" > "$AUTH_MANIFEST_TMP" \
        || { rm -f "$AUTH_MANIFEST_TMP"; echo "ERROR: failed to add 'auth/' to '$OUTPUT_VOLUME_FS/composer.json'" >&2; exit 1; }
    mv "$AUTH_MANIFEST_TMP" "$OUTPUT_VOLUME_FS/composer.json"

    #COMPOSER_DISABLE_NETWORK=1 like every other composer call in this target: a re-dump reads only
    #the already-installed vendor/, so it never needs the network - stating it makes that guarantee
    #explicit and greppable instead of resting on composer's implementation.
    if [ -d "$OUTPUT_VOLUME_FS/vendor" ]; then
        (cd "$OUTPUT_VOLUME_FS" && COMPOSER_DISABLE_NETWORK=1 composer dump-autoload --optimize --no-dev --no-interaction --ignore-platform-reqs) \
            || { echo "ERROR: failed to rebuild the optimized autoloader after adding 'auth/'" >&2; exit 1; }
    fi
fi

# -------------- END
echo ".proto to php library compilation finished successfully and output files are located in 'lib' directory of the mounted volume"
