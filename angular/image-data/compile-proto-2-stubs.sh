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
PROTO_FILES_CNT=$(find "$PROTOS_SRC_DIR" -iname "*.proto" | grep -c . || true)
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
ALL_PROTO_FILES=$(find "$PROTOS_SRC_DIR" -iname "*.proto")
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
ALL_PROTO_FILES=$(find "$PROTOS_SRC_DIR" -iname "*.proto")
# shellcheck disable=SC2086  # intentional word splitting of proto file list
for file in $ALL_PROTO_FILES; do
    # Check if any files match the pattern
    if [ -f "$file" ]; then
      echo "Removing 'optional ' from file: $file"
      # Only remove 'optional' keyword at the start of a field declaration (after leading whitespace),
      # not when 'optional' is used as a field name (e.g. "optional bool optional = 2;").
      # [[:space:]] and -i.bak keep this working with BSD/macOS sed too.
      sed -i.bak 's/^\([[:space:]]*\)optional /\1/' "$file" && rm -f "$file.bak"
    fi
done
echo "Done .proto remove optional keyword from proto files."

# -------------- Generate the proto client library stubs
echo "---------------------------------------------------------------"
echo "Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"
ALL_PROTO_FILES=$(find "$PROTOS_SRC_DIR" -iname "*.proto")
echo "Consuming .proto files: $ALL_PROTO_FILES: "

mkdir -p "$STUBS_TARGET_DIR"

# shellcheck disable=SC2086  # intentional word splitting of proto file list
protoc \
  --plugin=protoc-gen-ng="$PROTO_GEN_NG" \
  --ng_out="$STUBS_TARGET_DIR" \
  -I "$PROTOS_ROOT_DIR" \
  $ALL_PROTO_FILES

echo ".proto compilation finished."

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

STUB_FILES_CNT=$(find "$STUBS_TARGET_DIR" -iname "*.ts" | grep -c . || true)
echo "files generated by proto compilation: $STUB_FILES_CNT"

echo "DONE: execute script compile-proto-2-stubs.sh"
