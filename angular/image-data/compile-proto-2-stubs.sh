#!/bin/bash
set -e

echo "START: execute script compile-proto-2-stubs.sh"

STUBS_TARGET_DIR=$1
PROTOS_ROOT_DIR=$2
PROTOS_SRC_DIR=$3

PROTO_GEN_NG=./node_modules/.bin/protoc-gen-ng

#Find .protos in directory and count the occurrences
echo "---------------------------------------------------------------"
echo "Checking $PROTOS_SRC_DIR for .proto files"
echo "---------------------------------------------------------------"
if [ ! -d "$PROTOS_SRC_DIR" ]; then
  echo "ERROR: No proto files were found - the protos source directory '$PROTOS_SRC_DIR' does not exist - exiting" >&2
  exit 1
fi
#Every candidate is filtered through `[ -f ]`, not taken from -iname alone:
# * a DIRECTORY called e.g. "not-a-file.proto" satisfies the guard below and is then handed to
#   protoc as a positional input, which aborts with "Is a directory" instead of this script's
#   own message - and a lone decoy directory would let the whole no-protos guard pass;
# * `[ -f ]` rather than find's own -type f, because the test FOLLOWS symlinks and -type f does
#   not. The input volume is staged with `cp -r` (compile-proto-2-angular.sh), which copies
#   links verbatim, so a .proto a client symlinked into its protos dir is still a link here and
#   has to stay compilable. (`find -L ... -type f` says the same in one flag, but that option
#   has to precede the start path, which the BSD-portability gate over these scripts rejects.)
#The resulting list is the single source of truth for every pass below - re-running find per
#pass is what let the three consumers disagree about what a .proto is in the first place.
PROTO_CANDIDATES=$(find "$PROTOS_SRC_DIR" -iname "*.proto")
ALL_PROTO_FILES=""
DANGLING_PROTO_LINKS=""
PROTO_FILES_CNT=0
# shellcheck disable=SC2086  # intentional word splitting of the find result (proto paths have no spaces)
for candidate in $PROTO_CANDIDATES; do
  if [ -f "$candidate" ]; then
    ALL_PROTO_FILES="$ALL_PROTO_FILES $candidate"
    PROTO_FILES_CNT=$((PROTO_FILES_CNT + 1))
  elif [ -L "$candidate" ]; then
    #A link that resolves to nothing (or to a directory) would drop out of the set above without
    #a word - and a silently missing proto is a silently missing service in the client
    DANGLING_PROTO_LINKS="$DANGLING_PROTO_LINKS $candidate"
  fi
done
if [ -n "$DANGLING_PROTO_LINKS" ]; then
  echo "ERROR: these .proto symlinks do not resolve to a file:$DANGLING_PROTO_LINKS" >&2
  echo "       the mounted input volume is staged with 'cp -r', which keeps symlinks verbatim, so a link that leaves that volume (an absolute path, or a relative one reaching above it) dangles in the copy - point it inside the mounted directory or materialise the file - exiting" >&2
  exit 1
fi
if [[ $PROTO_FILES_CNT -lt 1 ]]; then
  echo "ERROR: No proto files were found in the '$PROTOS_SRC_DIR' directory, but are required to build a library from - exiting"
  exit 1
fi
echo "Found $PROTO_FILES_CNT .proto files in directory: $PROTOS_SRC_DIR"
echo "Source verified."

# -------------- record explicit presence BEFORE the optional keyword is stripped
# The strip below is what makes protoc-gen-ng emit usable code, but it also erases the only
# signal that tells "optional bool x = 5" apart from plain "bool x = 5" -- the code the plugin
# generates for the two is byte-identical, so nothing downstream can reconstruct it from the
# .ts. protoc records the distinction as proto3_optional on every FieldDescriptorProto, so a
# descriptor set taken here, and only here, is what fix-proto3-optional-presence.ts replays
# over the generated stubs once they exist.
echo "---------------------------------------------------------------"
echo "Recording proto3 explicit presence of the .proto files ..."
echo "---------------------------------------------------------------"
SCRIPT_DIRECTORY=$(cd "$(dirname "$0")" && pwd)
PRESENCE_DESCRIPTOR=$(mktemp "${TMPDIR:-/tmp}/proto3-optional-presence.XXXXXX")
trap 'rm -f "$PRESENCE_DESCRIPTOR"' EXIT
# shellcheck disable=SC2086  # intentional word splitting of proto file list
protoc \
  --descriptor_set_out="$PRESENCE_DESCRIPTOR" \
  -I "$PROTOS_ROOT_DIR" \
  $ALL_PROTO_FILES
echo "---------------------------------------------------------------"
echo "✅ Recorded proto3 explicit presence in $PRESENCE_DESCRIPTOR"
echo "---------------------------------------------------------------"

# -------------- remove optional keyword from proto files
echo "---------------------------------------------------------------"
echo "Starting .proto remove optional keyword from proto files  ..."
echo "---------------------------------------------------------------"
# shellcheck disable=SC2086  # intentional word splitting of proto file list
for file in $ALL_PROTO_FILES; do
    echo "Removing 'optional ' from file: $file"
    # Only remove 'optional' keyword at the start of a field declaration (after leading whitespace),
    # not when 'optional' is used as a field name (e.g. "optional bool optional = 2;").
    # [[:space:]] and -i.bak keep this working with BSD/macOS sed too.
    sed -i.bak 's/^\([[:space:]]*\)optional /\1/' "$file" && rm -f "$file.bak"
done
echo "Done .proto remove optional keyword from proto files."

# -------------- Generate the proto client library stubs
echo "---------------------------------------------------------------"
echo "Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"
echo "Consuming .proto files:$ALL_PROTO_FILES: "

mkdir -p "$STUBS_TARGET_DIR"

# shellcheck disable=SC2086  # intentional word splitting of proto file list
protoc \
  --plugin=protoc-gen-ng="$PROTO_GEN_NG" \
  --ng_out="$STUBS_TARGET_DIR" \
  -I "$PROTOS_ROOT_DIR" \
  $ALL_PROTO_FILES

echo ".proto compilation finished."

#-type f, not name alone: a directory whose name ends in .ts would inflate the reported count,
#and this line is the only report of how much protoc-gen-ng actually produced.
STUB_FILES_CNT=$(find "$STUBS_TARGET_DIR" -type f -iname "*.ts" | grep -c . || true)
echo "files generated by proto compilation: $STUB_FILES_CNT"
#...and the number is ACTED ON, not just printed: protoc exits 0 on an input set it generated
#nothing from, and an empty api/ then travels all the way to `ng build`, which fails much later
#with an unrelated error - or, worse, succeeds and ships a library with no stubs in it.
#Checked HERE, immediately after the protoc call that is supposed to have filled the tree, so
#the diagnosis names the generator - the codemod below has its own "no .ts stubs found" abort,
#and letting that one fire first blames the presence pass for protoc's empty run.
if [ "$STUB_FILES_CNT" -lt 1 ]; then
  echo "ERROR: protoc reported success but produced no '*.ts' sources in '$STUBS_TARGET_DIR' - there is nothing to build a library from - exiting" >&2
  exit 1
fi

# -------------- restore proto3 explicit presence in the generated stubs
# protoc-gen-ng coerces every unset field to its zero value in refineValues and then refuses to
# write a zero value at all, which makes false / 0 / "" unreachable for a field declared
# optional. The codemod rewrites exactly the (message, field) pairs the descriptor above marks
# proto3_optional, and fails the build rather than touching anything else.
echo "---------------------------------------------------------------"
echo "Starting proto3 explicit presence restoration in the stubs ..."
echo "---------------------------------------------------------------"
node "$SCRIPT_DIRECTORY/fix-proto3-optional-presence.ts" "$PRESENCE_DESCRIPTOR" "$STUBS_TARGET_DIR"
echo "---------------------------------------------------------------"
echo "✅ Done proto3 explicit presence restoration in the stubs"
echo "---------------------------------------------------------------"

echo "DONE: execute script compile-proto-2-stubs.sh"
