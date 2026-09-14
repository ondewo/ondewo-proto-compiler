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

# proto-deps.txt holds one bare proto path per line. The client may pre-seed it through the input
# volume (it is copied in with the rest of the mount), so `touch` must not truncate it and the
# lines already there must survive verbatim.
touch "$TEMP_SRC_DIRECTORY/proto-deps.txt"

#Matched by NAME and filtered with `[ -f ]` below - never with find's own `-type f`, the same
#filter compile-proto-2-stubs.sh applies to the very same directory: `-type f` does not follow a
#symlink, so a .proto a client symlinked into its protos dir was skipped here and every google/
#import it declares silently dropped from proto-deps.txt - the dependency stubs are then never
#generated and the shipped library imports modules that do not exist. `[ -f ]` follows the link;
#a DIRECTORY named "*.proto" still fails it (feeding one to the scan only produces an "Is a
#directory" error on stderr). NOT `find -L`: that flag has to precede the start path, which the
#BSD-portability gate rejects, and it makes find descend into symlinked directories, where a
#link loop can hang the run.
find "$COMPILE_SELECTED_PROTOS_DIR" -iname "*.proto" -print0 | while IFS= read -r -d '' protofile
do
    [ -f "$protofile" ] || continue
    # Pull the quoted path out of each google/ import statement. Parsing the statement instead of
    # chopping a fixed number of leading characters off the line is what makes an indented import,
    # an `import public` / `import weak`, and a client-supplied bare path all come out intact; the
    # `^[[:space:]]*import` anchor is what keeps a commented-out `// import "google/..."` out of
    # the list. grep exits 1 when a proto has no google/ import; that is normal, so do not abort
    # under set -e.
    sed -n 's|^[[:space:]]*import[[:space:]][[:space:]]*\(public[[:space:]][[:space:]]*\)\{0,1\}\(weak[[:space:]][[:space:]]*\)\{0,1\}"\([^"]*\)"[[:space:]]*;.*$|\3|p' "$protofile" \
        | grep "google/" >> "$TEMP_SRC_DIRECTORY/proto-deps.txt" || true
done

# Collapse the list. `sort -u`, never `sort | uniq -u`: -u on uniq prints only the lines that occur
# EXACTLY once, so a dependency imported by two protos was dropped from the list altogether rather
# than listed once, and protoc never generated its stubs.
sort -u "$TEMP_SRC_DIRECTORY/proto-deps.txt" | grep '[^[:space:]]' > "$TEMP_SRC_DIRECTORY/proto-deps.txt.tmp" || true
mv "$TEMP_SRC_DIRECTORY/proto-deps.txt.tmp" "$TEMP_SRC_DIRECTORY/proto-deps.txt"

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
#Remove previously generated stubs so protos deleted/renamed at source do not leave orphaned stubs
#behind. `${VAR:?}` like every other rm -rf in the repo: an empty $OUTPUT_VOLUME_FS would make
#this `rm -rf /api` instead of aborting.
rm -rf "${OUTPUT_VOLUME_FS:?}/api"
cp -r "$TEMP_SRC_DIRECTORY"/lib/* "$OUTPUT_VOLUME_FS" || { echo "ERROR: failed to copy library to output volume" >&2; exit 1; }
echo "Finished copying"

# -------------- Re-export the client's hand-written auth barrel from the generated public-api
bash ./append-auth-exports.sh "$OUTPUT_VOLUME_FS" || { echo "ERROR: append-auth-exports.sh failed" >&2; exit 1; }

# -------------- END
echo ".proto to typescript library compilation finished successfully and output files are located in 'lib' directory of the mounted volume"
