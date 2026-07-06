#!/bin/bash
set -e

#Root path of all the protos to be compiled
RELATIVE_PROTOS_DIR=$1
if [ -z "$1" ]; then
    RELATIVE_PROTOS_DIR="protos"
fi


#Container defaults; env-overridable so the script can run (and be tested) outside the image
IMAGE_DATA_DIRECTORY="${IMAGE_DATA_DIRECTORY:-/image-data}"
DEFAULT_FILES_DIR=$IMAGE_DATA_DIRECTORY/default-lib-files

#Input volumes mouted at root
INPUT_VOLUME_FS="${INPUT_VOLUME_FS:-/input-volume}"
OUTPUT_VOLUME_FS="${OUTPUT_VOLUME_FS:-/output-volume}"

TEMP_SRC_DIRECTORY=$IMAGE_DATA_DIRECTORY/src
#Copy source-volume contents to new directory (to not modify the original files during compilation)
mkdir -p "$TEMP_SRC_DIRECTORY"
cp -r "$INPUT_VOLUME_FS"/* "$TEMP_SRC_DIRECTORY" || { echo "ERROR: failed to copy input volume contents" >&2; exit 1; }

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
#rm -r $OUTPUT_VOLUME_FS/*

# -------------- Check if all the requirements are there and exist if not
echo "Checking if all the source requirements are fulfilled ..."

if [ ! -f "$TEMP_SRC_DIRECTORY/tsconfig.json" ]; then
    echo "No tsconfig.json specified in source directory -> copying default file"
    cp "$DEFAULT_FILES_DIR/tsconfig.json" "$TEMP_SRC_DIRECTORY/tsconfig.json"
fi

if [ ! -f "$TEMP_SRC_DIRECTORY/package.json" ]; then
    echo "ERROR: A package.json file was not specified in the mounted directory this is however required - exitting"
    exit 1
fi

touch "$TEMP_SRC_DIRECTORY/proto-deps.txt"
find "$COMPILE_SELECTED_PROTOS_DIR" -iname "*.proto" -print0 | while IFS= read -r -d '' protofile
do
    # grep exits 1 when a proto has no google/ import; that is normal, so do not abort under set -e
    cat "$protofile" | grep import | grep "google/" >> "$TEMP_SRC_DIRECTORY/proto-deps.txt" || true
done

REMOVE_LINES=""
for import in $(cat "$TEMP_SRC_DIRECTORY/proto-deps.txt" | grep "\"" | cut -c 7- )
do
    OCCURENCES=$(cat "$TEMP_SRC_DIRECTORY/proto-deps.txt" | grep "$import" | wc -l)
    if [ "$OCCURENCES" -gt 1 ]; then
        for line in $(cat "$TEMP_SRC_DIRECTORY/proto-deps.txt" | grep -n "$import" | cut -d':' -f1 | tail -n +2)
        do
            REMOVE_LINES=$REMOVE_LINES";$line""d"
        done
    fi
done
REMOVE_LINES=$(echo "$REMOVE_LINES" | cut -c 2-)

# -i.bak (not bare -i) keeps this working with both GNU and BSD/macOS sed
if [ -n "$REMOVE_LINES" ]; then
    sed -i.bak -e "$REMOVE_LINES" "$TEMP_SRC_DIRECTORY/proto-deps.txt"
    rm -f "$TEMP_SRC_DIRECTORY/proto-deps.txt.bak"
fi

REMOVE_IMPORT=$(cat "$TEMP_SRC_DIRECTORY/proto-deps.txt"  | cut -c 8- | sed 's/\"//g' | sed 's/\;//')
echo "$REMOVE_IMPORT" > "$TEMP_SRC_DIRECTORY/proto-deps.txt"

REMOVE_DUPLICATES=$(sort "$TEMP_SRC_DIRECTORY/proto-deps.txt" | uniq -u)
echo "$REMOVE_DUPLICATES" > "$TEMP_SRC_DIRECTORY/proto-deps.txt"

echo "Google Protos Dependencies:"
cat "$TEMP_SRC_DIRECTORY/proto-deps.txt"


# -------------- Running compilation steps
bash ./compile-proto-2-stubs.sh "$TEMP_SRC_DIRECTORY/api" "$PROTOS_ROOT_PATH" "$COMPILE_SELECTED_PROTOS_DIR" "$TEMP_SRC_DIRECTORY/proto-deps.txt" || { echo "ERROR: compile-proto-2-stubs.sh failed" >&2; exit 1; }
bash ./make-lib-entry-point.sh "$TEMP_SRC_DIRECTORY" .d.ts || { echo "ERROR: make-lib-entry-point.sh (.d.ts) failed" >&2; exit 1; }
bash ./make-lib-entry-point.sh "$TEMP_SRC_DIRECTORY" .js || { echo "ERROR: make-lib-entry-point.sh (.js) failed" >&2; exit 1; }
bash ./compile-stubs-2-lib.sh "$TEMP_SRC_DIRECTORY" || { echo "ERROR: compile-stubs-2-lib.sh failed" >&2; exit 1; }

# -------------- Copy results back to mounted directory

echo "Copying output files to mounted directory"
#mkdir -p $INPUT_VOLUME_FS/lib
#Remove previously generated stubs so protos deleted/renamed at source do not leave orphaned stubs behind
rm -rf "$OUTPUT_VOLUME_FS/api"
cp -r "$TEMP_SRC_DIRECTORY"/lib/* "$OUTPUT_VOLUME_FS" || { echo "ERROR: failed to copy library to output volume" >&2; exit 1; }
echo "Finished copying"

# -------------- END
echo ".proto to typescript library compilation finished successfully and output files are located in 'lib' directory of the mounted volume"
