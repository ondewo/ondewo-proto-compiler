STUBS_TARGET_DIR=$1
PROTOS_ROOT_DIR=$2
PROTOS_SRC_DIR=$3

PROTO_GEN_NG=./node_modules/.bin/protoc-gen-ng

#Find .protos in directory and count the occurances
echo "Checking $PROTOS_SRC_DIR for .proto files"
PROTO_FILES_CNT=$(tree $PROTOS_SRC_DIR | fgrep .proto | wc -l)
if [[ $PROTO_FILES_CNT -lt 1 ]]; then
    echo "ERROR: No proto files were found in the '$PROTOS_SRC_DIR' directory, but are required to build a library from - exitting"
    exit 1
fi
echo "Found $PROTO_FILES_CNT .proto files in directory: $PROTO_FILES_CNT"
echo "Source verified."

# -------------- Generate the proto client library stubs
echo "Starting .proto to grpc client stubs compilation ..."
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
