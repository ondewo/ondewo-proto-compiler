#!/bin/bash
set -e

# ---------------------------------------------------------------------------------------
# Orchestrator (the image ENTRYPOINT) of the .proto -> rust crate pipeline.
#
#   compile-proto-2-rust.sh <relative_protos_dir> [<target_subdir>]
#
#   $1  path of the proto root, RELATIVE to the mounted input volume (default "protos").
#       This is what protoc gets as -I, so it is the root the `import "x/y.proto";` paths
#       of every proto resolve against. For a client SDK this is "ondewo-nlu-api".
#   $2  optional sub-directory of that proto root to compile. Empty means "every .proto
#       under the proto root". For a client SDK this is "ondewo", which scopes generation
#       to the service protos and pulls the vendored google/ tree in only as a resolved
#       dependency.
# ---------------------------------------------------------------------------------------

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

#Working directories inside the image
# TEMP_SRC_DIRECTORY   private copy of the input volume - the mount itself is never mutated
# CRATE_DIRECTORY      the cargo crate that is assembled, compiled and packaged
# DIST_DIRECTORY       where the packaged *.crate tarball is collected before the copy-back
TEMP_SRC_DIRECTORY="${TEMP_SRC_DIRECTORY:-$IMAGE_DATA_DIRECTORY/src}"
CRATE_DIRECTORY="${CRATE_DIRECTORY:-$IMAGE_DATA_DIRECTORY/crate}"
DIST_DIRECTORY="${DIST_DIRECTORY:-$IMAGE_DATA_DIRECTORY/dist}"

echo "---------------------------------------------------------------"
echo "Rust: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

# -------------- Validate the mounted input before touching anything
if [ ! -d "$INPUT_VOLUME_FS" ]; then
    echo "ERROR: the input volume '$INPUT_VOLUME_FS' does not exist - mount your sources with '-v <dir>:/input-volume' - exiting" >&2
    exit 1
fi
if [ ! -d "$DEFAULT_FILES_DIR" ]; then
    echo "ERROR: the default library files directory '$DEFAULT_FILES_DIR' does not exist - the image is incomplete - exiting" >&2
    exit 1
fi

#Copy source-volume contents to new directory (to not modify the original files during compilation).
#`cp -r "$INPUT_VOLUME_FS"/*` would fail on an empty mount long before the far more
#descriptive proto guards below run, so copy the directory CONTENTS with the "/." form,
#which tolerates emptiness and carries dotfiles across too.
rm -rf "${TEMP_SRC_DIRECTORY:?}"
mkdir -p "$TEMP_SRC_DIRECTORY"
cp -r "$INPUT_VOLUME_FS"/. "$TEMP_SRC_DIRECTORY"/ || { echo "ERROR: failed to copy input volume contents from '$INPUT_VOLUME_FS'" >&2; exit 1; }

#Everything downstream reads from the private copy, never from the mount: compile-proto-2-stubs.sh
#cd's into the proto root, and protoc's inherited CWD is what protoc-gen-prost-crate resolves
#its gen_crate template against - that must not be a directory inside the user's mount.
PROTOS_ROOT_PATH="$TEMP_SRC_DIRECTORY/$RELATIVE_PROTOS_DIR"
if [ ! -d "$PROTOS_ROOT_PATH" ]; then
    echo "ERROR: No proto files were found - the protos root directory '$RELATIVE_PROTOS_DIR' does not exist in the mounted input volume '$INPUT_VOLUME_FS' - exiting" >&2
    exit 1
fi

#If not specified take all protos in the protos root path (otherwise a relative directory)
#Subdir of the protos to be compiled
COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/$2
if [ -z "$2" ]; then
    COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/
fi
if [ ! -d "$COMPILE_SELECTED_PROTOS_DIR" ]; then
    echo "ERROR: No proto files were found - the target sub-directory '$2' does not exist in the protos root '$RELATIVE_PROTOS_DIR' - exiting" >&2
    exit 1
fi

#Clean output volume if exists
if [ ! -d "$OUTPUT_VOLUME_FS" ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUT_VOLUME_FS=$INPUT_VOLUME_FS/lib
    mkdir -p "$OUTPUT_VOLUME_FS"
fi

# -------------- Assemble the crate the generated stubs are compiled into
# Only src/ and Cargo.toml are taken over from the input volume - deliberately NOT a
# rust-toolchain.toml or a .cargo/config.toml, which would repoint the toolchain or the
# registry and cannot work under the image's baked CARGO_NET_OFFLINE=true.
echo "Assembling the cargo crate in '$CRATE_DIRECTORY' ..."
rm -rf "${CRATE_DIRECTORY:?}" "${DIST_DIRECTORY:?}"
mkdir -p "$CRATE_DIRECTORY/src"
if [ -d "$TEMP_SRC_DIRECTORY/src" ]; then
    echo "Found hand-written sources in the input volume -> copying them into the crate"
    cp -r "$TEMP_SRC_DIRECTORY/src"/. "$CRATE_DIRECTORY/src"/ || { echo "ERROR: failed to copy the hand-written src/ directory into the crate" >&2; exit 1; }
fi
#src/api is ENTIRELY generated and must never be seeded from the input volume: a client's
#hand-written modules and the generated tree share one src/ directory, so on a re-run with
#the input and output volumes pointing at the same tree the previous run's stubs come back
#in with the copy above and would survive the copy-back's wipe as orphans. protoc re-creates
#the directory (compile-proto-2-stubs.sh does `mkdir -p "$CRATE_DIR" "$CRATE_API_DIR"`).
rm -rf "${CRATE_DIRECTORY:?}/src/api"

# -------------- Check if all the requirements are there and exit if not
echo "Checking if all the source requirements are fulfilled ..."

#The manifest template protoc-gen-prost-crate copies to <crate>/Cargo.toml (js-style default,
#not typescript's hard requirement - but a real client should always ship its own).
MANIFEST_TEMPLATE=$TEMP_SRC_DIRECTORY/Cargo.toml
if [ ! -f "$MANIFEST_TEMPLATE" ]; then
    echo "WARN: no Cargo.toml in the mounted input volume -> using the image default crate name 'ondewo-proto-stubs'; ship your own Cargo.toml to publish under a client-specific name" >&2
    MANIFEST_TEMPLATE=$DEFAULT_FILES_DIR/Cargo.toml
fi
if [ ! -f "$MANIFEST_TEMPLATE" ]; then
    echo "ERROR: the crate manifest template '$MANIFEST_TEMPLATE' does not exist - exiting" >&2
    exit 1
fi
echo "Using crate manifest template: $MANIFEST_TEMPLATE"

# -------------- Running compilation steps
bash ./compile-proto-2-stubs.sh "$CRATE_DIRECTORY" "$PROTOS_ROOT_PATH" "$COMPILE_SELECTED_PROTOS_DIR" "$MANIFEST_TEMPLATE" || { echo "ERROR: compile-proto-2-stubs.sh failed" >&2; exit 1; }
bash ./make-lib-entry-point.sh "$CRATE_DIRECTORY" || { echo "ERROR: make-lib-entry-point.sh failed" >&2; exit 1; }
bash ./compile-stubs-2-lib.sh "$CRATE_DIRECTORY" "$DIST_DIRECTORY" || { echo "ERROR: compile-stubs-2-lib.sh failed" >&2; exit 1; }

# -------------- Copy results back to mounted directory
echo "Copying output files to mounted directory"

#Remove previously generated output so protos deleted/renamed at source do not leave orphans
#behind. Only the two ENTIRELY generated paths are wiped: hand-written code under src/ that
#sits outside api/ survives, which is exactly why the stubs are confined to src/api.
rm -rf "${OUTPUT_VOLUME_FS:?}/src/api"
rm -rf "${OUTPUT_VOLUME_FS:?}/crate-dist"

mkdir -p "$OUTPUT_VOLUME_FS/src"
cp -r "$CRATE_DIRECTORY/src"/. "$OUTPUT_VOLUME_FS/src"/ || { echo "ERROR: failed to copy the generated src/ tree to the output volume" >&2; exit 1; }
cp "$CRATE_DIRECTORY/Cargo.toml" "$OUTPUT_VOLUME_FS/Cargo.toml" || { echo "ERROR: failed to copy Cargo.toml to the output volume" >&2; exit 1; }

#A lockfile only exists once cargo has resolved (it is seeded from the image's pre-warmed one);
#shipping it is what makes a consumer's offline build reproducible.
if [ -f "$CRATE_DIRECTORY/Cargo.lock" ]; then
    cp "$CRATE_DIRECTORY/Cargo.lock" "$OUTPUT_VOLUME_FS/Cargo.lock" || { echo "ERROR: failed to copy Cargo.lock to the output volume" >&2; exit 1; }
fi

#The packaged tarball is absent when the cargo build/package step was skipped (SKIP_CARGO_BUILD=1)
if [ -d "$DIST_DIRECTORY" ] && find "$DIST_DIRECTORY" -type f -name "*.crate" | grep -q .; then
    mkdir -p "$OUTPUT_VOLUME_FS/crate-dist"
    cp "$DIST_DIRECTORY"/*.crate "$OUTPUT_VOLUME_FS/crate-dist"/ || { echo "ERROR: failed to copy the packaged crate to the output volume" >&2; exit 1; }
else
    echo "WARN: no packaged *.crate artifact was produced -> the output volume carries the crate sources only" >&2
fi
echo "Finished copying"

# -------------- END
echo "---------------------------------------------------------------"
echo "✅ Rust: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
echo ".proto to rust library compilation finished successfully and the generated crate is located in the mounted output volume"
