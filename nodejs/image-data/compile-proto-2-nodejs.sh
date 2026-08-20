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

#Input volumes module at root
INPUT_VOLUME_FS="${INPUT_VOLUME_FS:-/input-volume}"
OUTPUT_VOLUME_FS="${OUTPUT_VOLUME_FS:-/output-volume}"

TEMP_SRC_DIRECTORY=$IMAGE_DATA_DIRECTORY/src
#Copy source-volume contents to new directory (to not modify the original files during compilation)
mkdir -p "$TEMP_SRC_DIRECTORY"
cp -r "$INPUT_VOLUME_FS/"* "$TEMP_SRC_DIRECTORY"

PROTOS_ROOT_PATH=$INPUT_VOLUME_FS/$RELATIVE_PROTOS_DIR

#If not specified take all protos in the protos root path (otherwise a relative directory)
#Subdir of the protos to be compiled
COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/$2
echo "COMPILE_SELECTED_PROTOS_DIR=$COMPILE_SELECTED_PROTOS_DIR"
if [ -z "$2" ]; then
    echo "Adjusted: COMPILE_SELECTED_PROTOS_DIR=$COMPILE_SELECTED_PROTOS_DIR"
    COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/
fi


#Clean output volume if exists
if [ ! -d "$OUTPUT_VOLUME_FS" ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUT_VOLUME_FS=$INPUT_VOLUME_FS/lib
    mkdir -p "$OUTPUT_VOLUME_FS"
fi
#rm -r $OUTPUT_VOLUME_FS/*
#Clean previously generated stubs so renamed/deleted protos are not shipped as stale output
if [ -n "$OUTPUT_VOLUME_FS" ] && [ -d "$OUTPUT_VOLUME_FS" ]; then
    rm -rf "${OUTPUT_VOLUME_FS:?}/api"
fi

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
# shellcheck disable=SC2044  # intentional iteration over find-listed proto files (paths have no spaces)
for protofile in $(find "$COMPILE_SELECTED_PROTOS_DIR" -iname "*.proto")
do
    echo "ONDEWO: For loop: $protofile"
    # FIXME: this does not work since it might be that the proto which is referenced references again another proto
    # grep exits 1 when a proto has no google/ import; that is normal, so do not abort under set -e
    cat "$protofile" | grep import | grep "google/" >> "$TEMP_SRC_DIRECTORY/proto-deps.txt" || true
done

# shellcheck disable=SC2044  # intentional iteration over find-listed proto files (paths have no spaces)
for protofile in $(find "$COMPILE_SELECTED_PROTOS_DIR/../google" -iname "*.proto" | grep -E "api|rpc|type" | grep -vE "streetview|storagetransfer|spanner|vision|monitoring|automl|bigquery|dataproc|dialogflow|appengine|bigtable|datastore|firestore|genomics|home|googleads|experimental|devtools|experimental|servicecontrol|servicemanagement")
do
    echo "Google: For loop: $protofile"
    # workaround: since it might be that the proto which is referenced references again another proto
    # grep exits 1 when a proto has no google/ import; that is normal, so do not abort under set -e
    cat "$protofile" | grep import | grep "google/" >> "$TEMP_SRC_DIRECTORY/proto-deps.txt" || true
done


#for protofile in $(find $COMPILE_SELECTED_PROTOS_DIR -iname "*.proto")
#do
#    echo "For loop: $protofile"
#    # FIXME: this does not work since it might be that the proto which is referenced references again another proto
#    cat $protofile | grep import | grep "google/" >> $TEMP_SRC_DIRECTORY/proto-deps.txt
#
#    cat $protofile | grep import | grep "google/" >> $TEMP_SRC_DIRECTORY/tmp_rec_1.txt
#
#    echo "$TEMP_SRC_DIRECTORY/tmp_rec_1.txt: $TEMP_SRC_DIRECTORY/tmp_rec_1.txt"
#    cat $TEMP_SRC_DIRECTORY/tmp_rec_1.txt
#
#    for dep_file_rec_1 in $TEMP_SRC_DIRECTORY/tmp_rec_1.txt
#    do
#        cat $dep_file_rec_1 | grep import | grep "google/" >> $TEMP_SRC_DIRECTORY/proto-deps.txt
#        cat $dep_file_rec_1 | grep import | grep "google/" >> $TEMP_SRC_DIRECTORY/tmp_rec_2.txt
#
#        echo "$TEMP_SRC_DIRECTORY/tmp_rec_2.txt:"
#        cat $TEMP_SRC_DIRECTORY/tmp_rec_2.txt
#
#        for dep_file_rec_2 in $TEMP_SRC_DIRECTORY/tmp_rec_2.txt
#        do
#          echo "dep_file_rec_2: $dep_file_rec_2"
#          cat $dep_file_rec_2 | grep import | grep "google/" >> $TEMP_SRC_DIRECTORY/proto-deps.txt
#        done
#        rm $TEMP_SRC_DIRECTORY/tmp_rec_2.txt
#    done
#    rm $TEMP_SRC_DIRECTORY/tmp_rec_1.txt
#done

echo "Google Protos Dependencies:"
sort "$TEMP_SRC_DIRECTORY/proto-deps.txt" | uniq > "$TEMP_SRC_DIRECTORY/proto-deps-unique.txt"
mv "$TEMP_SRC_DIRECTORY/proto-deps-unique.txt" "$TEMP_SRC_DIRECTORY/proto-deps.txt"
cat "$TEMP_SRC_DIRECTORY/proto-deps.txt"


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
bash ./compile-proto-2-stubs.sh "$TEMP_SRC_DIRECTORY/api" "$PROTOS_ROOT_PATH" "$COMPILE_SELECTED_PROTOS_DIR" "$TEMP_SRC_DIRECTORY/proto-deps.txt"
bash ./make-lib-entry-point.sh "$TEMP_SRC_DIRECTORY" .d.ts
bash ./make-lib-entry-point.sh "$TEMP_SRC_DIRECTORY" .js
bash ./compile-stubs-2-lib.sh "$TEMP_SRC_DIRECTORY"

# -------------- Copy results back to mounted directory

echo "Copying output files to mounted directory"
#mkdir -p $INPUT_VOLUME_FS/lib
cp -r "$TEMP_SRC_DIRECTORY/lib/"* "$OUTPUT_VOLUME_FS"
echo "Finished copying"

# -------------- Re-export the client's hand-written auth barrel from the generated public-api
bash ./append-auth-exports.sh "$OUTPUT_VOLUME_FS" || { echo "ERROR: append-auth-exports.sh failed" >&2; exit 1; }

# -------------- END
echo ".proto to nodejs library compilation finished successfully and output files are located in 'lib' directory of the mounted volume"
