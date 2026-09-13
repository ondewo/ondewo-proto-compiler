#!/bin/bash
set -e

STUBS_TARGET_DIR=$1
PROTOS_ROOT_DIR=$2
PROTOS_SRC_DIR=$3
GO_IMPORT_PREFIX=$4

if [ -z "$STUBS_TARGET_DIR" ] || [ -z "$PROTOS_ROOT_DIR" ] || [ -z "$PROTOS_SRC_DIR" ] || [ -z "$GO_IMPORT_PREFIX" ]; then
    echo "usage: compile-proto-2-stubs.sh <stubs_target_dir> <protos_root_dir> <protos_src_dir> <go_import_prefix>" >&2
    exit 1
fi
#The relative proto paths below are cut off this prefix - a trailing slash would leave the
#relative names starting with a '/' and the M keys would stop matching protoc's file names
PROTOS_ROOT_DIR=${PROTOS_ROOT_DIR%/}
#find keeps the start path verbatim in every result (BSD find even appends its own separator on
#top of a trailing one), so a trailing slash here doubles the separator, the google/** exclusion
#below stops matching and the vendored google protos get generated into the client module. When
#no target sub-directory was selected the caller passes "$PROTOS_ROOT_PATH/", which names the
#same existing directory without the slash.
PROTOS_SRC_DIR=${PROTOS_SRC_DIR%/}

if [ ! -d "$PROTOS_ROOT_DIR" ]; then
    echo "ERROR: the protos root directory '$PROTOS_ROOT_DIR' does not exist - exiting" >&2
    exit 1
fi

echo "Make proto generation target directory: $STUBS_TARGET_DIR"
#The source tree is a verbatim copy of the input volume, which for a go client is the repository
#itself - so it may well already carry the api/ directory of a previous run. Those stale stubs
#would be staged, compiled and copied back out, and a stub of a proto that no longer exists is
#not dead weight in go: it either breaks the build or re-registers a descriptor path at init.
rm -rf "${STUBS_TARGET_DIR:?}"
mkdir -p "$STUBS_TARGET_DIR"

#Find .protos in directory and count the occurances
echo "Checking $PROTOS_SRC_DIR for .proto files"
if [ ! -d "$PROTOS_SRC_DIR" ]; then
    echo "ERROR: No proto files were found - the protos source directory '$PROTOS_SRC_DIR' does not exist - exiting" >&2
    exit 1
fi
#Every candidate is filtered through `[ -f ]`, not by find's own -type f:
# * not by -iname alone, because a DIRECTORY called e.g. "not-a-file.proto" would satisfy the
#   guard below and then be handed to protoc as a positional input, which aborts with "Is a
#   directory" instead of this script's own message;
# * `[ -f ]` rather than -type f, because the test FOLLOWS symlinks and -type f does not. The
#   input volume is staged with `cp -r`, which copies links verbatim, so a .proto the client
#   symlinked into its protos dir is still a link here and has to stay compilable.
#   (`find -L ... -type f` says the same in one flag, but that option has to precede the start
#   path, which the BSD-portability gate over these scripts rejects.)
#A proto reachable only THROUGH a symlinked directory is a different case and stays out: find
#does not descend into one, and never did.
SELECTED_PROTO_CANDIDATES=$(find "$PROTOS_SRC_DIR" -iname "*.proto")
SELECTED_PROTO_FILES=""
DANGLING_PROTO_LINKS=""
PROTO_FILES_CNT=0
# shellcheck disable=SC2086  # intentional word splitting of the find result (proto paths have no spaces)
for candidate in $SELECTED_PROTO_CANDIDATES; do
    if [ -f "$candidate" ]; then
        SELECTED_PROTO_FILES="$SELECTED_PROTO_FILES $candidate"
        PROTO_FILES_CNT=$((PROTO_FILES_CNT + 1))
    elif [ -L "$candidate" ]; then
        #A link that resolves to nothing (or to a directory) would drop out of the set above
        #without a word - and a silently missing proto is a silently missing service
        DANGLING_PROTO_LINKS="$DANGLING_PROTO_LINKS $candidate"
    fi
done
if [ -n "$DANGLING_PROTO_LINKS" ]; then
    echo "ERROR: these .proto symlinks do not resolve to a file:$DANGLING_PROTO_LINKS" >&2
    echo "       the mounted input volume is staged with 'cp -r', which keeps symlinks verbatim, so a link that leaves that volume (an absolute path, or a relative one reaching above it) dangles in the copy - point it inside the mounted directory or materialise the file - exiting" >&2
    exit 1
fi
if [ "$PROTO_FILES_CNT" -lt 1 ]; then
    echo "ERROR: No proto files were found in the '$PROTOS_SRC_DIR' directory, but are required to build a library from - exiting" >&2
    exit 1
fi
echo "Found $PROTO_FILES_CNT .proto files in directory: $PROTOS_SRC_DIR"
echo "Source verified."

# -------------- Map every .proto this module owns onto a go import path
# The ONDEWO protos either carry no `option go_package` at all - protoc-gen-go then aborts with
# "unable to determine Go import path" - or, in the four files forked from Google Dialogflow,
# carry Google's own, which would generate them into
# google.golang.org/genproto/googleapis/cloud/dialogflow/v2. An M<proto>=<import path> flag per
# file fixes both cases: the M flag takes precedence over the go_package option in the source.
# The mappings cover every non-google proto under the proto ROOT, not just the compiled
# sub-directory, because protoc-gen-go needs an import path for dependency files too.
# google/** is deliberately left out: those protos keep their own (correct) go_package and are
# imported from google.golang.org/protobuf and google.golang.org/genproto. Generating them here
# as well would register the same descriptor path twice and panic every consumer at init.
ALL_PROTO_FILES=$(find "$PROTOS_ROOT_DIR" -iname "*.proto")
GO_IMPORT_MAPPINGS=""
# shellcheck disable=SC2086  # intentional word splitting of the find result (proto paths have no spaces)
for protofile in $ALL_PROTO_FILES; do
    #The same `[ -f ]` filter as the selected set above, for the same two reasons: a directory
    #named "*.proto" would earn an M mapping whose key protoc never resolves to a file, while a
    #symlinked proto is a real dependency and keeps its mapping
    [ -f "$protofile" ] || continue
    rel_proto=${protofile#"$PROTOS_ROOT_DIR"}
    #Strip EVERY leading separator, not just one: a doubled slash anywhere in the start path
    #survives into find's output, and a rel_proto of "/google/..." would slip past the exclusion
    while [ "$rel_proto" != "${rel_proto#/}" ]; do
        rel_proto=${rel_proto#/}
    done
    case $rel_proto in
        google/*) continue ;;
    esac
    rel_dir=$(dirname "$rel_proto")
    if [ "$rel_dir" = "." ]; then
        go_import_path=$GO_IMPORT_PREFIX
    else
        go_import_path=$GO_IMPORT_PREFIX/$rel_dir
    fi
    # protogen derives the Go package NAME from the .proto's own go_package option BEFORE
    # consulting the M flag ("NOTE: The package name is derived first from the import path in
    # the 'go_package' option (if present) before trying the 'M' flag."). The four
    # Dialogflow-forked protos declare go_package = ".../cloud/dialogflow/v2;dialogflow", so an
    # M flag carrying only an import path leaves them named `dialogflow` in a directory whose
    # other files are named `nlu` -> protoc-gen-go aborts with "has inconsistent names" before
    # a single file is written. Pinning the name in the M flag itself is what fixes it.
    # (sed, not `tr -c`: tr would also rewrite the trailing newline and yield "nlu_".)
    go_pkg_name=$(basename "$go_import_path" | sed 's|[^A-Za-z0-9_]|_|g')
    GO_IMPORT_MAPPINGS="$GO_IMPORT_MAPPINGS --go_opt=M$rel_proto=$go_import_path;$go_pkg_name --go-grpc_opt=M$rel_proto=$go_import_path;$go_pkg_name"
done

#The files actually handed to protoc
COMPILE_PROTO_FILES=""
# shellcheck disable=SC2086  # intentional word splitting of the find result (proto paths have no spaces)
for protofile in $SELECTED_PROTO_FILES; do
    rel_proto=${protofile#"$PROTOS_ROOT_DIR"}
    #Same here: without stripping every leading separator a google/** proto reached through a
    #doubled slash would be handed to protoc and re-register its descriptor path in the client
    while [ "$rel_proto" != "${rel_proto#/}" ]; do
        rel_proto=${rel_proto#/}
    done
    case $rel_proto in
        google/*) continue ;;
    esac
    COMPILE_PROTO_FILES="$COMPILE_PROTO_FILES $protofile"
done

if [ -z "$COMPILE_PROTO_FILES" ]; then
    echo "ERROR: only google/** protos were found in '$PROTOS_SRC_DIR' - those are never generated here, their go packages come from google.golang.org/protobuf and google.golang.org/genproto - exiting" >&2
    exit 1
fi

# -------------- Generate the proto client library stubs
echo "Starting .proto to grpc client stubs compilation ..."
echo "Consuming .proto files: $COMPILE_PROTO_FILES: "

# shellcheck disable=SC2086  # intentional word splitting of the option and proto file lists
protoc \
-I "$PROTOS_ROOT_DIR" \
--go_out="$STUBS_TARGET_DIR" \
--go_opt=paths=source_relative \
--go-grpc_out="$STUBS_TARGET_DIR" \
--go-grpc_opt=paths=source_relative \
$GO_IMPORT_MAPPINGS \
$COMPILE_PROTO_FILES

echo ".proto compilation finished."

#-type f, not name alone: a directory whose name ends in .go would inflate the reported count.
#No symlink filter here (unlike the proto finds above) - this tree was wiped and rewritten by
#protoc a few lines up, so every entry in it is a file protoc-gen-go just created.
STUB_FILES_CNT=$(find "$STUBS_TARGET_DIR" -type f -iname "*.go" | grep -c . || true)
echo "files generated by proto compilation: $STUB_FILES_CNT"
