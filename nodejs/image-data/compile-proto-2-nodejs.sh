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

# proto-deps.txt holds one bare proto path per line. The client may pre-seed it through the input
# volume (it is copied in with the rest of the mount - the target's own example ships one), so
# `touch` must not truncate it and the lines already there must survive verbatim.
touch "$TEMP_SRC_DIRECTORY/proto-deps.txt"
#-print0 + `read -d ''` instead of `for protofile in $(find ...)`: the unquoted command
#substitution word-split every path on whitespace, so a proto below a directory with a space in
#its name was never read and every google/ import it declares was silently dropped from
#proto-deps.txt - the dependency protos are then never compiled and the shipped library imports
#stubs that do not exist.
#Matched by NAME and filtered with `[ -f ]` below - never with find's own `-type f`, the same
#filter compile-proto-2-stubs.sh applies to the very same directory: `-type f` does not follow a
#symlink, so a symlinked .proto was skipped here and lost its google/ imports in exactly the way
#described above. `[ -f ]` follows the link; a DIRECTORY named e.g. "vendor.proto" still fails
#it. NOT `find -L`: that flag has to precede the start path, which the BSD-portability gate
#rejects, and it makes find descend into symlinked directories, where a link loop can hang.
find "$COMPILE_SELECTED_PROTOS_DIR" -iname "*.proto" -print0 | while IFS= read -r -d '' protofile
do
    [ -f "$protofile" ] || continue
    echo "ONDEWO: For loop: $protofile"
    # FIXME: this does not work since it might be that the proto which is referenced references again another proto
    # Pull the quoted path out of each google/ import statement. Parsing the statement instead of
    # chopping a fixed number of leading characters off the line (`cut -c 8-`) is what makes an
    # indented import, a legal `import public` / `import weak`, and a client-supplied bare path
    # all come out intact; the `^[[:space:]]*import` anchor is what keeps a commented-out
    # `// import "google/...";` out of the list. grep exits 1 when a proto has no google/ import;
    # that is normal, so do not abort under set -e.
    sed -n 's|^[[:space:]]*import[[:space:]][[:space:]]*\(public[[:space:]][[:space:]]*\)\{0,1\}\(weak[[:space:]][[:space:]]*\)\{0,1\}"\([^"]*\)"[[:space:]]*;.*$|\3|p' "$protofile" \
        | grep "google/" >> "$TEMP_SRC_DIRECTORY/proto-deps.txt" || true
done

#The well-known / API protos the compiled tree imports live in a sibling google/ directory. A proto
#set that ships none is legitimate (the example's protos/ has no google/), so the directory is
#checked up front: find used to fail with "No such file or directory" on stderr, which reads like a
#build error, while the loop was skipped and the run carried on regardless - loud and useless in the
#one case, and no diagnostic at all about the dependency scan not having run.
GOOGLE_PROTOS_DIR=$COMPILE_SELECTED_PROTOS_DIR/../google
if [ ! -d "$GOOGLE_PROTOS_DIR" ]; then
    echo "No google protos directory at '$GOOGLE_PROTOS_DIR' -> skipping the google dependency scan"
else
    #Same NAME match + `[ -f ]` filter as the entry-set scan above, for the same reasons
    find "$GOOGLE_PROTOS_DIR" -iname "*.proto" -print0 | while IFS= read -r -d '' protofile
    do
        [ -f "$protofile" ] || continue
        #the include/exclude filters used to be greps over find's output; applying them to one path
        #at a time is the same test on the same string and keeps the NUL-delimited stream intact
        if ! printf '%s\n' "$protofile" | grep -qE "api|rpc|type"; then
            continue
        fi
        if printf '%s\n' "$protofile" | grep -qE "streetview|storagetransfer|spanner|vision|monitoring|automl|bigquery|dataproc|dialogflow|appengine|bigtable|datastore|firestore|genomics|home|googleads|experimental|devtools|experimental|servicecontrol|servicemanagement"; then
            continue
        fi
        echo "Google: For loop: $protofile"
        # workaround: since it might be that the proto which is referenced references again another proto
        # Same statement parser as the entry-set scan above (see the comment there); the transitive
        # dependencies feed the very same list, so they have to be normalised the very same way.
        sed -n 's|^[[:space:]]*import[[:space:]][[:space:]]*\(public[[:space:]][[:space:]]*\)\{0,1\}\(weak[[:space:]][[:space:]]*\)\{0,1\}"\([^"]*\)"[[:space:]]*;.*$|\3|p' "$protofile" \
            | grep "google/" >> "$TEMP_SRC_DIRECTORY/proto-deps.txt" || true
    done
fi


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

# Collapse the list. `sort -u`, never `sort | uniq -u`: -u on uniq prints only the lines that occur
# EXACTLY once, so a dependency imported by two protos was dropped from the list altogether rather
# than listed once, and protoc never generated its stubs. The entries are already bare paths - the
# statement parser above emits nothing else - so there is no positional post-processing left to do:
# the `cut -c 8-` that used to run here mangled every line the parser now hands over intact, and the
# substring-regex line deletion it fed could take the whole list with it.
sort -u "$TEMP_SRC_DIRECTORY/proto-deps.txt" | grep '[^[:space:]]' > "$TEMP_SRC_DIRECTORY/proto-deps.txt.tmp" || true
mv "$TEMP_SRC_DIRECTORY/proto-deps.txt.tmp" "$TEMP_SRC_DIRECTORY/proto-deps.txt"

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
