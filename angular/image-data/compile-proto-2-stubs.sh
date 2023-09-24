echo "START: execute script compile-proto-2-stubs.sh"

STUBS_TARGET_DIR=$1
PROTOS_ROOT_DIR=$2
PROTOS_SRC_DIR=$3

PROTO_GEN_NG=./node_modules/.bin/protoc-gen-ng

#Find .protos in directory and count the occurrences
echo "---------------------------------------------------------------"
echo "Checking $PROTOS_SRC_DIR for .proto files"
echo "---------------------------------------------------------------"
PROTO_FILES_CNT=$(tree $PROTOS_SRC_DIR | fgrep .proto | wc -l)
if [[ $PROTO_FILES_CNT -lt 1 ]]; then
  echo "ERROR: No proto files were found in the '$PROTOS_SRC_DIR' directory, but are required to build a library from - exitting"
  exit 1
fi
echo "Found $PROTO_FILES_CNT .proto files in directory: $PROTO_FILES_CNT"
echo "Source verified."

# -------------- remove optional keyword from proto files - Note: note needed anymore
echo "---------------------------------------------------------------"
echo "Starting .proto remove optional keyword from proto files  ..."
echo "---------------------------------------------------------------"
ALL_PROTO_FILES=$(find $PROTOS_SRC_DIR -iname "*.proto")
SEARCH_TEXT="optional "
for file in $ALL_PROTO_FILES; do
    # Check if any files match the pattern
    if [ -f "$file" ]; then
      echo "Removing 'optional ' from file: $file"
      sed -i "s/$SEARCH_TEXT//g" "$file"
    fi
done
echo "Done .proto remove optional keyword from proto files."

# -------------- Generate the proto client library stubs
echo "---------------------------------------------------------------"
echo "Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"
ALL_PROTO_FILES=$(find $PROTOS_SRC_DIR -iname "*.proto")
echo "Consuming .proto files: $ALL_PROTO_FILES: "

mkdir -p $STUBS_TARGET_DIR

protoc \
  --plugin=protoc-gen-ng=$PROTO_GEN_NG \
  --ng_out=$STUBS_TARGET_DIR \
  -I $PROTOS_ROOT_DIR \
  $ALL_PROTO_FILES

echo ".proto compilation finished."

STUB_FILES_CNT=$(tree $STUBS_TARGET_DIR | fgrep .ts | wc -l)
echo "files generated by proto compilation: $STUB_FILES_CNT"

echo "DONE: execute script compile-proto-2-stubs.sh"
