#!/bin/bash
set -e

#Root directory of the compilation -> go.mod/go.sum + the generated stubs
SRC_DIRECTORY=$1
STUBS_SUBDIR=$2
if [ -z "$STUBS_SUBDIR" ]; then
    STUBS_SUBDIR=api
fi

if [ -z "$SRC_DIRECTORY" ]; then
    echo "usage: compile-stubs-2-lib.sh <src_directory> [stubs_subdir]" >&2
    exit 1
fi
if [ ! -f "$SRC_DIRECTORY/go.mod" ]; then
    echo "ERROR: no go.mod in '$SRC_DIRECTORY' - the module manifest is rendered by compile-proto-2-go.sh from default-lib-files/go.mod.template and is required to build the generated stubs - exiting" >&2
    exit 1
fi
if [ ! -d "$SRC_DIRECTORY/$STUBS_SUBDIR" ]; then
    echo "ERROR: no generated stubs in '$SRC_DIRECTORY/$STUBS_SUBDIR' - compile-proto-2-stubs.sh has to run first - exiting" >&2
    exit 1
fi

# -------------- Start the go build process
echo "Starting go build process of library package ..."

LIB_DIRECTORY=$SRC_DIRECTORY/lib
rm -rf "${LIB_DIRECTORY:?}"
mkdir -p "$LIB_DIRECTORY"

#The library is staged as a self contained module: the generated stubs plus the manifest that
#was resolved at image build time, and nothing else. Hand written sources of the consuming
#repository are deliberately left out - their own dependencies are not in this image's module
#cache, and the build here must not reach the network (GOPROXY=off).
cp "$SRC_DIRECTORY/go.mod" "$LIB_DIRECTORY/go.mod"
if [ -f "$SRC_DIRECTORY/go.sum" ]; then
    cp "$SRC_DIRECTORY/go.sum" "$LIB_DIRECTORY/go.sum"
fi
cp -r "$SRC_DIRECTORY/$STUBS_SUBDIR" "$LIB_DIRECTORY/$STUBS_SUBDIR"

cd "$LIB_DIRECTORY" || exit 1

#`go build ./...` emits no artifact for library packages - it is here because it type checks
#every generated file against the pinned protobuf/grpc/genproto runtimes, which is what turns a
#broken import mapping, a missing dependency package or a plugin/runtime skew into a failure
#here instead of in the client repository.
echo "Executing 'go build ./...' in $LIB_DIRECTORY"
if ! go build ./...; then
    echo "ERROR: 'go build ./...' failed in $LIB_DIRECTORY" >&2
    echo "       If a target sub-directory was selected (2nd argument of compile-proto-2-go.sh), it has to be" >&2
    echo "       closed over every non-google .proto that the selected protos import - protoc-gen-go emits a go" >&2
    echo "       import for a dependency proto even when protoc reports the import as unused, so a bare 'import'" >&2
    echo "       line is enough ('import lookup disabled by -mod=readonly' above says exactly that)." >&2
    echo "       'module lookup disabled by GOPROXY=off' instead means the stubs import a module that was not" >&2
    echo "       pre-downloaded when the image was built -> add it to image-data/default-lib-files/warmup.go and" >&2
    echo "       rebuild the image." >&2
    exit 1
fi

echo "Finished go build."
