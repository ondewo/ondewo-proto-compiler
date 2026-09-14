#!/bin/bash
. "$(dirname "$0")"/dependecy-resolver.sh

STUBS_TARGET_DIR="$1"
PROTOS_ROOT_DIR="$2"
PROTOS_SRC_DIR="$3"

#Exit on error
set -e

echo "Stubs target dir: $STUBS_TARGET_DIR"
echo "Protos root dir: $PROTOS_ROOT_DIR"
echo "Protos src dir: $PROTOS_SRC_DIR"

#Find .protos in directory and count the occurances
echo "Checking $PROTOS_SRC_DIR for .proto files"

if [ ! -d "$PROTOS_SRC_DIR" ]; then
    echo "ERROR: No proto files were found - the protos source directory '$PROTOS_SRC_DIR' does not exist - exiting" >&2
    exit 1
fi
#Matched by NAME and then filtered with `test -f` - never with find's own `-type f`. This is the
#`[ -f ]` filter angular/ and go/ apply, written in find's own syntax so that a path containing a
#newline reaches the resolver whole instead of being re-split by a shell loop:
#  * `-type f` does not follow a symlink, and the input volume is staged with `cp -r`, which
#    keeps links verbatim - so a .proto a client symlinked into its protos dir was silently
#    dropped from the compile set (measured: find -type f returns 1 of 2). `test -f` follows it.
#  * the name alone is not enough either: a DIRECTORY named e.g. "session.proto" would satisfy
#    the guard below and then be carried into the dependency resolver as an input "file", where
#    it resolves to nothing and aborts the build instead of simply not being a proto.
#  * NOT `find -L ... -type f`: that spelling has to put the flag BEFORE the start path, which
#    the BSD-portability gate over these scripts rejects, and -L makes find DESCEND into
#    symlinked directories, where a link loop can hang the run. Plain find never descends one,
#    so a looping link is just a link that fails `test -f` and is reported by the guard below.
ENTRY_PROTO_FILES=$(find "$PROTOS_SRC_DIR" -iname "*.proto" -exec test -f {} \; -print)
#A .proto symlink that resolves to nothing (or to a directory) drops out of the set above without
#a word - and a silently missing proto is a silently missing service in the client. `sed`+`tr`
#join the hits onto the message line exactly the way angular/ and go/ spell it.
DANGLING_PROTO_LINKS=$(find "$PROTOS_SRC_DIR" -type l -iname "*.proto" -exec test ! -f {} \; -print | sed 's|^| |' | tr -d '\n')
if [ -n "$DANGLING_PROTO_LINKS" ]; then
    echo "ERROR: these .proto symlinks do not resolve to a file:$DANGLING_PROTO_LINKS" >&2
    echo "       the mounted input volume is staged with 'cp -r', which keeps symlinks verbatim, so a link that leaves that volume (an absolute path, or a relative one reaching above it) dangles in the copy - point it inside the mounted directory or materialise the file - exiting" >&2
    exit 1
fi
if [ -z "$ENTRY_PROTO_FILES" ]; then
    echo "ERROR: No proto files were found in the '/protos' directory, but are required to build a library from - exiting" >&2
    exit 1
fi
PROTO_FILES_CNT=$(printf '%s\n' "$ENTRY_PROTO_FILES" | grep -c .)
echo "Found $PROTO_FILES_CNT .proto files in directory: $PROTOS_SRC_DIR"
echo "Source verified."

#ONE_FILE=$(echo "$ENTRY_PROTO_FILES" | head -n 1)
#echo "$ONE_FILE"
#ALL_PROTO_FILES=$(echoProtoDependencies "$PROTOS_ROOT_DIR" "$ONE_FILE")
export -f echoDependencies
export -f echoProtoDependencies
#echo "$ENTRY_PROTO_FILES" | xargs -I % bash -c "$(echoProtoDependencies "$PROTOS_ROOT_DIR" "%")"
#ALL_PROTO_FILES=$(echo "$ENTRY_PROTO_FILES" | xargs -I % bash -c "echoProtoDependencies \"$PROTOS_ROOT_DIR\" %" | tac | tr "\n" " ")
#ALL_PROTO_FILES=$(echoProtoDependencies "$ENTRY_PROTO_FILES" "$PROTOS_ROOT_DIR" | tac | tr "\n" " ")
if ! ALL_PROTO_FILES=$(echoProtoDependencies "$PROTOS_ROOT_DIR" "$ENTRY_PROTO_FILES"); then
    echo "Dependency resolution failed" >&2
    exit 1
fi
ALL_PROTO_FILES=$(printf '%s\n' "$ALL_PROTO_FILES" | sort -u | tr "\n" " ")
#ALL_PROTO_FILES=$(printf "%s\n%s" "$ENTRY_PROTO_FILES" "$ALL_PROTO_FILES")
# tr -d strips BSD/macOS wc's leading-space field padding (GNU wc emits a bare count)
ALL_PROTO_FILES_CNT=$(echo "$ALL_PROTO_FILES" | wc -w | tr -d ' ')

# -------------- Generate the proto client library stubs
echo "Starting .proto to grpc client stubs compilation ..."
echo "Consuming $ALL_PROTO_FILES_CNT .proto files: $ALL_PROTO_FILES ... "

mkdir -p "$STUBS_TARGET_DIR"

echo "Target dir: $STUBS_TARGET_DIR"
echo "Root dir: $PROTOS_ROOT_DIR"
printf "Files to compile: \n%s\n\n" "$ALL_PROTO_FILES"

CWD=$(pwd)

cd "$PROTOS_ROOT_DIR"

#mode=grpcwebtext mode=grpcweb
# shellcheck disable=SC2086  # intentional word splitting of proto file list
protoc \
--js_out=import_style=commonjs,binary:"$STUBS_TARGET_DIR" \
--grpc-web_out=import_style=commonjs,mode=grpcwebtext:"$STUBS_TARGET_DIR" \
-I "$PROTOS_ROOT_DIR" \
$ALL_PROTO_FILES

echo ""

#protoc \
#--js_out=import_style=commonjs,binary:"$STUBS_TARGET_DIR" \
#--grpc-web_out=import_style=commonjs+dts,mode=grpcwebtext:"$STUBS_TARGET_DIR" \
#-I "$PROTOS_ROOT_DIR" \
#"$ALL_PROTO_FILES"

echo ".proto compilation finished."

cd "$CWD"


#`-type f` for the same reason as the entry-proto scan above: a DIRECTORY named "*.js" (the input
#volume is copied into the stubs target dir, so a user directory lands here) is not a generated
#stub and must not inflate the reported count.
#`*_pb.js`, not `*.js`: this target has no separable generated sub-tree the way the others have
#api/ - compile-proto-2-js.sh passes the whole staged copy of the input volume as the stubs
#target dir, so an unfiltered count tallies webpack.js, webpack.common.js, webpack.dev.js and
#every source file the client mounted, and reports a comfortable non-zero number for a run that
#generated nothing at all. Both js generators write into that one name-space: --js_out emits
#<proto>_pb.js and --grpc-web_out emits <proto>_grpc_web_pb.js, which ends in _pb.js too.
#`grep -c . || true` instead of `wc -l`: BSD/macOS wc pads its output with spaces, and grep -c
#exits 1 on an empty list, which must not abort the script under `set -e`
STUB_FILES_CNT=$(find "$STUBS_TARGET_DIR" -type f -iname "*_pb.js" | grep -c . || true)
echo "files generated by proto compilation: $STUB_FILES_CNT"
#...and the number is ACTED ON, not just printed: protoc exits 0 on an input set it generated
#nothing from, and webpack then bundles a public-api.js that re-exports nothing.
if [ "$STUB_FILES_CNT" -lt 1 ]; then
    echo "ERROR: protoc reported success but produced no '*_pb.js' sources in '$STUBS_TARGET_DIR' - there is nothing to build a library from - exiting" >&2
    exit 1
fi
