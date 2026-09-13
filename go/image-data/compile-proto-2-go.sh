#!/bin/bash
set -e

echo "START: execute script compile-proto-2-go.sh"

#Root path of all the protos to be compiled (relative to the mounted input volume)
RELATIVE_PROTOS_DIR=$1
if [ -z "$1" ]; then
    RELATIVE_PROTOS_DIR="protos"
fi
#A trailing slash would be doubled into every proto path handed to protoc, and the relative
#proto paths are the keys of the go import mappings -> normalise it away right here
RELATIVE_PROTOS_DIR=${RELATIVE_PROTOS_DIR%/}

#Container defaults; env-overridable so the script can run (and be tested) outside the image
IMAGE_DATA_DIRECTORY="${IMAGE_DATA_DIRECTORY:-/image-data}"

#Input volumes mounted at root
INPUT_VOLUME_FS="${INPUT_VOLUME_FS:-/input-volume}"
OUTPUT_VOLUME_FS="${OUTPUT_VOLUME_FS:-/output-volume}"

TEMP_SRC_DIRECTORY="${TEMP_SRC_DIRECTORY:-$IMAGE_DATA_DIRECTORY/src}"

if [ ! -d "$INPUT_VOLUME_FS" ]; then
    echo "ERROR: the input volume '$INPUT_VOLUME_FS' does not exist - mount the directory holding the protos into the container with '-v <your directory>:/input-volume' - exiting" >&2
    exit 1
fi

#Copy source-volume contents to new directory (to not modify the original files during compilation)
mkdir -p "$TEMP_SRC_DIRECTORY"
cp -r "$INPUT_VOLUME_FS"/* "$TEMP_SRC_DIRECTORY" || { echo "ERROR: failed to copy input volume contents" >&2; exit 1; }

#Everything below compiles out of the copy - the mounted input volume is only ever read
PROTOS_ROOT_PATH=$TEMP_SRC_DIRECTORY/$RELATIVE_PROTOS_DIR
if [ ! -d "$PROTOS_ROOT_PATH" ]; then
    echo "ERROR: the protos root directory '$RELATIVE_PROTOS_DIR' (1st argument) does not exist in the mounted input volume '$INPUT_VOLUME_FS' - exiting" >&2
    exit 1
fi

#If not specified take all protos in the protos root path (otherwise a relative directory)
#Subdir of the protos to be compiled
COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/${2%/}
if [ -z "$2" ]; then
    COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/
fi

#Clean output volume if exists
if [ ! -d "$OUTPUT_VOLUME_FS" ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUT_VOLUME_FS=$INPUT_VOLUME_FS/lib
    mkdir -p "$OUTPUT_VOLUME_FS"
fi

# -------------- Check if all the requirements are there and exit if not
echo "Checking if all the source requirements are fulfilled ..."

# In go the import path of a generated package is part of the generated code, so the module
# path has to be known before protoc runs: the 3rd argument wins, otherwise the `module` line
# of a go.mod in the mounted directory is used.
GO_MODULE_PATH=$3
if [ -z "$GO_MODULE_PATH" ] && [ -f "$TEMP_SRC_DIRECTORY/go.mod" ]; then
    GO_MODULE_PATH=$(sed -n 's|^module[[:space:]][[:space:]]*\([^[:space:]]*\).*|\1|p' "$TEMP_SRC_DIRECTORY/go.mod" | head -1)
fi
if [ -z "$GO_MODULE_PATH" ]; then
    echo "ERROR: no go module path - pass it as the 3rd argument (e.g. github.com/ondewo/ondewo-nlu-client-go)" >&2
    echo "       or provide a go.mod with a 'module <path>' line in the mounted input directory - exiting" >&2
    exit 1
fi
#A trailing slash would double up in every generated import path and in the rendered go.mod
GO_MODULE_PATH=${GO_MODULE_PATH%/}
case $GO_MODULE_PATH in
    *[[:space:]]*|/*)
        echo "ERROR: '$GO_MODULE_PATH' is not a usable go module path - it must be an import path such as github.com/ondewo/ondewo-nlu-client-go, without whitespace and without a leading '/' - exiting" >&2
        exit 1
        ;;
esac
echo "Go module path: $GO_MODULE_PATH"

#Generated stubs live under api/ (same layout as the other targets), so their go import path
#is <module>/api/<directory of the .proto>
STUBS_SUBDIR=api

# -------------- Running compilation steps
bash ./compile-proto-2-stubs.sh "$TEMP_SRC_DIRECTORY/$STUBS_SUBDIR" "$PROTOS_ROOT_PATH" "$COMPILE_SELECTED_PROTOS_DIR" "$GO_MODULE_PATH/$STUBS_SUBDIR" || { echo "ERROR: compile-proto-2-stubs.sh failed" >&2; exit 1; }

# -------------- Module manifest of the generated library
# Go has no entry point file to generate - a package IS its directory and there is no star
# export - so there is no make-lib-entry-point.sh here. What turns the generated directories
# into importable packages is go.mod, and it is NOT taken from the mounted repository: it is
# the manifest resolved when the image was built, so the `go build` below is satisfied entirely
# from the module cache baked into the image and never reaches the network.
#Location of the default files - resolved relative to this script, not to the caller's CWD
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_FILES_DIR=$SCRIPT_DIRECTORY/default-lib-files

if [ ! -f "$DEFAULT_FILES_DIR/go.mod.template" ]; then
    echo "ERROR: $DEFAULT_FILES_DIR/go.mod.template is missing - the image was built without the pre-resolved go module manifest - exiting" >&2
    exit 1
fi
if ! grep -q '@GO_MODULE_PATH@' "$DEFAULT_FILES_DIR/go.mod.template"; then
    echo "ERROR: $DEFAULT_FILES_DIR/go.mod.template carries no @GO_MODULE_PATH@ placeholder - its module line would name the image's warm-up module instead of '$GO_MODULE_PATH' and every generated import would dangle - exiting" >&2
    exit 1
fi

echo "Writing go.mod for module $GO_MODULE_PATH"
sed -e "s|@GO_MODULE_PATH@|$GO_MODULE_PATH|" "$DEFAULT_FILES_DIR/go.mod.template" > "$TEMP_SRC_DIRECTORY/go.mod"

#go.sum has to match the go.mod rendered above, so a go.sum that came in with the mounted
#repository is dropped rather than left to contradict it (with GOFLAGS=-mod=readonly a stale
#entry is a hard "missing go.sum entry" failure).
if [ -f "$DEFAULT_FILES_DIR/go.sum" ]; then
    cp "$DEFAULT_FILES_DIR/go.sum" "$TEMP_SRC_DIRECTORY/go.sum"
else
    echo "WARNING: no pre-resolved $DEFAULT_FILES_DIR/go.sum - the module cache of this image may be incomplete" >&2
    rm -f "$TEMP_SRC_DIRECTORY/go.sum"
fi

bash ./compile-stubs-2-lib.sh "$TEMP_SRC_DIRECTORY" "$STUBS_SUBDIR" || { echo "ERROR: compile-stubs-2-lib.sh failed" >&2; exit 1; }

# -------------- Copy results back to mounted directory
echo "Copying output files to mounted directory"
#Remove previously generated stubs so protos deleted/renamed at source leave no orphans behind
rm -rf "${OUTPUT_VOLUME_FS:?}/$STUBS_SUBDIR"
cp -r "$TEMP_SRC_DIRECTORY/lib/$STUBS_SUBDIR" "$OUTPUT_VOLUME_FS/$STUBS_SUBDIR" || { echo "ERROR: failed to copy stubs to output volume" >&2; exit 1; }

#go.mod / go.sum are the manifest of the CONSUMING repository, which may pin dependencies of
#its own hand written packages -> write them only when the output volume has none, never
#overwrite a hand maintained one.
#The two are ONE unit, not two independent files - the same reasoning the build tree above
#already applies: the staged go.sum resolves exactly the go.mod rendered from the image's
#template. Dropping it beside a KEPT hand maintained go.mod (clients commonly gitignore go.sum)
#leaves a sum file that cannot satisfy that manifest, and the client's next `go build` fails
#with "missing go.sum entry". So either both are written or neither is.
if [ -f "$OUTPUT_VOLUME_FS/go.mod" ] || [ -f "$OUTPUT_VOLUME_FS/go.sum" ]; then
    for manifest in go.mod go.sum; do
        if [ -f "$OUTPUT_VOLUME_FS/$manifest" ]; then
            echo "$manifest already exists in the output volume -> keeping it"
        else
            echo "$manifest is not written -> it would contradict the output volume's own manifest"
        fi
    done
else
    for manifest in go.mod go.sum; do
        if [ -f "$TEMP_SRC_DIRECTORY/lib/$manifest" ]; then
            cp "$TEMP_SRC_DIRECTORY/lib/$manifest" "$OUTPUT_VOLUME_FS/$manifest" || { echo "ERROR: failed to copy $manifest to output volume" >&2; exit 1; }
        fi
    done
fi
echo "The generated stubs require these modules (make sure a hand maintained go.mod lists them):"
grep -v '^module ' "$TEMP_SRC_DIRECTORY/lib/go.mod" || true
echo "Finished copying"

# -------------- END
echo ".proto to go library compilation finished successfully and output files are located in the '$STUBS_SUBDIR' directory of the mounted output volume"
echo "DONE: execute script compile-proto-2-go.sh"
