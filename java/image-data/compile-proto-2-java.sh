#!/bin/bash
set -e

# -------------- Orchestrator: ENTRYPOINT of the ondewo-java-proto-compiler image
# Turns the .proto files mounted at /input-volume into a self-contained, standalone-buildable
# maven project in /output-volume (pom.xml + src/main/java + target/*.jar).
#
#   compile-proto-2-java.sh <relative_protos_dir> [<target_subdir>] \
#                           [<group_id>] [<artifact_id>] [<version>]
#
# Args 1-2 are exactly the nodejs / typescript / angular shape; args 3-5 are the java analogue
# of the js target's <lib_entry_name>: java has no package.json in the input volume to read the
# library identity from, and reading it from a mounted pom.xml would fight the offline build.

echo "START: execute script compile-proto-2-java.sh"

#Root path of all the protos to be compiled (relative to the input volume) -> protoc's -I root
RELATIVE_PROTOS_DIR=$1
if [ -z "$1" ]; then
    RELATIVE_PROTOS_DIR="protos"
fi

#Subdirectory of the protos root to compile; empty = every .proto below the root
TARGET_SUBDIR=$2

#Maven coordinates of the generated library
MAVEN_GROUP_ID=$3
if [ -z "$3" ]; then
    MAVEN_GROUP_ID="com.ondewo"
fi
MAVEN_ARTIFACT_ID=$4
if [ -z "$4" ]; then
    MAVEN_ARTIFACT_ID="ondewo-proto-stubs-java"
fi
#ONDEWO_PROTO_COMPILER_VERSION is baked into the image by the Dockerfile ARG of the same name,
#and kept in sync with the root Makefile by the release targets.
LIBRARY_VERSION=$5
if [ -z "$5" ]; then
    LIBRARY_VERSION="${ONDEWO_PROTO_COMPILER_VERSION:-0.0.0}"
fi

#Container defaults; env-overridable so the script can run (and be tested) outside the image
IMAGE_DATA_DIRECTORY="${IMAGE_DATA_DIRECTORY:-/image-data}"
DEFAULT_FILES_DIR=$IMAGE_DATA_DIRECTORY/default-lib-files

#Input volumes mouted at root
INPUT_VOLUME_FS="${INPUT_VOLUME_FS:-/input-volume}"
OUTPUT_VOLUME_FS="${OUTPUT_VOLUME_FS:-/output-volume}"

#Trailing slashes are stripped (portable BRE; `${var%/}` would strip only one), because every
#path below is derived from this one by string concatenation.
TEMP_SRC_DIRECTORY=$(printf '%s' "${TEMP_SRC_DIRECTORY:-$IMAGE_DATA_DIRECTORY/src}" | sed 's|/\{1,\}$||')

if [ ! -d "$INPUT_VOLUME_FS" ]; then
    echo "ERROR: the input volume '$INPUT_VOLUME_FS' does not exist - mount the directory that" >&2
    echo "       holds the protos at /input-volume - exiting" >&2
    exit 1
fi

#Copy source-volume contents to new directory (to not modify the original files during compilation)
mkdir -p "$TEMP_SRC_DIRECTORY"
cp -r "$INPUT_VOLUME_FS"/* "$TEMP_SRC_DIRECTORY" || { echo "ERROR: failed to copy input volume contents" >&2; exit 1; }

#Everything below works on the COPY, never on the mount - so the mounted protos stay pristine
#even though the java_package rewrite below edits them.
PROTOS_ROOT_PATH=$TEMP_SRC_DIRECTORY/$RELATIVE_PROTOS_DIR
if [ ! -d "$PROTOS_ROOT_PATH" ]; then
    echo "ERROR: the protos root directory '$RELATIVE_PROTOS_DIR' (arg 1) does not exist inside the" >&2
    echo "       mounted input volume '$INPUT_VOLUME_FS' - exiting" >&2
    exit 1
fi

#If not specified take all protos in the protos root path (otherwise a relative directory)
#Subdir of the protos to be compiled
COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/$TARGET_SUBDIR
if [ -z "$TARGET_SUBDIR" ]; then
    COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/
    echo "No target subdirectory (arg 2) given -> compiling every .proto below '$PROTOS_ROOT_PATH'."
    echo "The vendored google/ tree is always excluded: its java classes ship in protobuf-java and"
    echo "proto-google-common-protos. Pass a subdirectory (e.g. 'ondewo') to scope the compilation -"
    echo "a protos root spanning several independent trees is refused rather than compiled wholesale."
fi
echo "Compiling protos from: $COMPILE_SELECTED_PROTOS_DIR"

#Create lib dir for output if no output specified
if [ ! -d "$OUTPUT_VOLUME_FS" ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUT_VOLUME_FS=$INPUT_VOLUME_FS/lib
    mkdir -p "$OUTPUT_VOLUME_FS"
fi

# -------------- Rewrite the Dialogflow-inherited java_package in the TEMP COPY
# Four ondewo-nlu-api protos (common, context, entity_type, session) still carry
# `option java_package = "com.google.cloud.dialogflow.v2";`. Left alone, ~93% of the generated
# library would publish ONDEWO classes into Google's namespace and hard-break any consumer that
# also has google-cloud-dialogflow on the classpath (split package, first-on-classpath wins) -
# and nothing would fail loudly, because the generation itself succeeds. The proper fix belongs
# upstream in ondewo-nlu-api; until it lands, rewrite it here on the copy (the angular target
# precedents editing the temp copy before protoc). `-i.bak` + delete, never bare `sed -i`, so
# this works with both GNU and BSD/macOS sed.
echo "Rewriting any inherited com.google.cloud.dialogflow.v2 java_package in the temporary copy"
#`-exec test -f {} \;` rather than find's own `-type f`, the same filter compile-proto-2-stubs.sh
#applies to the compile set: a DIRECTORY named e.g. "vendor.proto" is still skipped (`-type f`
#skipped it too, and without the filter sed aborts the run with its obscure "couldn't edit ...:
#not a regular file"), but `test -f` FOLLOWS a symlink while -type f does not - and a proto the
#client symlinked into its protos dir is copied here as a link by the `cp -r` above. Skipped, it
#would be compiled WITHOUT this rewrite and its stubs would ship in com.google.cloud.dialogflow.v2
#after all, which is the whole failure this block exists to prevent.
#The vendored google/ tree is excluded here for the same reason it is excluded as a protoc
#input in compile-proto-2-stubs.sh: it is somebody else's namespace. A googleapis checkout
#carries google/cloud/dialogflow/v2/*.proto, whose java_package IS the literal replaced here -
#repackaging those into com.ondewo.nlu would make an ondewo proto that imports one generate
#references to com.ondewo.nlu classes that no jar provides. `!` (not `-not`) and an explicit
#start path, for GNU/BSD portability.
find "$TEMP_SRC_DIRECTORY" -name "*.proto" ! -path "*/google/*" -exec test -f {} \; -exec sed -i.bak \
    's|^option java_package = "com.google.cloud.dialogflow.v2";|option java_package = "com.ondewo.nlu";|' {} +
#Deliberately NOT narrowed to the set above: this deletes sed's backups, and a broad sweep also
#clears any left behind in a reused temp copy by an earlier run (the image runs once per
#container, a local or test run does not). Only the throwaway copy is ever touched.
#`! -type d` rather than `-type f`: sed -i.bak renames the ORIGINAL out of the way, so the backup
#of a symlinked proto is itself a symlink and `-type f` would leave it behind. A directory is
#excluded because -delete cannot remove a non-empty one and would fail the run.
find "$TEMP_SRC_DIRECTORY" ! -type d -name "*.proto.bak" -delete

# -------------- Check if all the requirements are there and exist if not
echo "Checking if all the source requirements are fulfilled ..."

#Standard maven layout: the generated stubs are a java source root inside the project.
#The project is a SIBLING of the input-volume copy, never a directory inside it: the `cp -r`
#above reproduces every top-level entry of the mount in $TEMP_SRC_DIRECTORY, so a client that
#keeps an unrelated `java/` at its input-volume root would otherwise have it merged into the
#build - its `java/target/*.jar` picked up by compile-stubs-2-lib.sh and shipped as part of the
#generated library, its `java/pom.xml` silently replacing the rendered template.
MAVEN_PROJECT_DIR=${TEMP_SRC_DIRECTORY}-maven-project
STUBS_TARGET_DIR=$MAVEN_PROJECT_DIR/src/main/java
#Nothing from the input volume can land here any more, so the directory is ours alone and is
#rebuilt from scratch: a project left behind by an earlier run against the same filesystem (the
#image runs once per container, a local or test run does not) must not leak its pom.xml or its
#stale stubs into this one.
rm -rf "${MAVEN_PROJECT_DIR:?}"
mkdir -p "$MAVEN_PROJECT_DIR"

#A pom.xml at the input volume root wins over the default template (make-lib-entry-point.sh
#keeps it and warns that only the versions pre-warmed into the image resolve offline)
if [ -f "$TEMP_SRC_DIRECTORY/pom.xml" ]; then
    echo "A pom.xml was specified in the mounted input volume -> using it instead of the default file"
    cp "$TEMP_SRC_DIRECTORY/pom.xml" "$MAVEN_PROJECT_DIR/pom.xml"
fi

if [ -f "$TEMP_SRC_DIRECTORY/LICENSE" ]; then
    cp "$TEMP_SRC_DIRECTORY/LICENSE" "$MAVEN_PROJECT_DIR/LICENSE"
else
    echo "No LICENSE file specified in source directory -> copying default file"
    cp "$DEFAULT_FILES_DIR/LICENSE" "$MAVEN_PROJECT_DIR/LICENSE"
fi

# -------------- Running compilation steps
echo "START: Executing \"compile-proto-2-stubs.sh\"..."
bash ./compile-proto-2-stubs.sh "$STUBS_TARGET_DIR" "$PROTOS_ROOT_PATH" "$COMPILE_SELECTED_PROTOS_DIR" || { echo "ERROR: compile-proto-2-stubs.sh failed" >&2; exit 1; }
echo "DONE: Executing \"compile-proto-2-stubs.sh\"..."

# -------------- Remove the stubs this run regenerates from the output volume
# Java has no single generated subtree the way nodejs has api/: hand-written client sources
# (a client's Keycloak/bearer auth surface) live under src/main/java too, and they share the
# TOP-LEVEL package root - `com/` or `ondewo/` - with the generated stubs. Wiping that root
# would therefore delete them (the java analogue of angular's destructive `rm -rf npm`, but
# silent), so the sweep is narrowed to the LEAF package directories protoc actually wrote
# into, and to the *.java files in them. A proto deleted or renamed at source still leaves no
# orphan in its own package, while `com/ondewo/nlu/auth/` and every other sibling package
# survives. The residual tradeoff is a hand-written class placed in exactly the same package
# as generated stubs - keep hand-written sources in their own package.
# Runs AFTER stub generation (the tree has to exist) and BEFORE the copy-back.
echo "Removing previously generated stubs from the java packages this run regenerates"
find "$STUBS_TARGET_DIR" -type f -name "*.java" -exec dirname {} \; | sort -u | while IFS= read -r gen_dir; do
    rel=${gen_dir#"$STUBS_TARGET_DIR"}
    rel=${rel#/}
    #The source root itself (the default java package) is never swept: it is where a client's
    #own top-level sources would sit, and generated stubs always carry a package.
    [ -n "$rel" ] || continue
    rm -f "${OUTPUT_VOLUME_FS:?}/src/main/java/$rel"/*.java
done

echo "START: Executing \"make-lib-entry-point.sh\"..."
bash ./make-lib-entry-point.sh "$MAVEN_PROJECT_DIR" "$MAVEN_GROUP_ID" "$MAVEN_ARTIFACT_ID" "$LIBRARY_VERSION" || { echo "ERROR: make-lib-entry-point.sh failed" >&2; exit 1; }
echo "DONE: Executing \"make-lib-entry-point.sh\"..."

echo "START: Executing \"compile-stubs-2-lib.sh\"..."
bash ./compile-stubs-2-lib.sh "$MAVEN_PROJECT_DIR" || { echo "ERROR: compile-stubs-2-lib.sh failed" >&2; exit 1; }
echo "DONE: Executing \"compile-stubs-2-lib.sh\"..."

# -------------- Copy results back to mounted directory
if [ -f "$OUTPUT_VOLUME_FS/pom.xml" ]; then
    echo "WARNING: '$OUTPUT_VOLUME_FS/pom.xml' already exists and is about to be OVERWRITTEN by the"
    echo "WARNING: generated build descriptor. Mount the pom.xml you want to keep at the INPUT volume"
    echo "WARNING: root instead - it is then carried through the generation unchanged."
fi

#The shipped library always carries a LICENSE (the caller's, or the default Apache-2.0 one),
#so the copy-back below replaces any LICENSE already in the output volume. Same class of
#destructive overwrite as the pom.xml above, and just as loud.
if [ -f "$OUTPUT_VOLUME_FS/LICENSE" ]; then
    echo "WARNING: '$OUTPUT_VOLUME_FS/LICENSE' already exists and is about to be OVERWRITTEN by the"
    echo "WARNING: library LICENSE. Mount the LICENSE you want to keep at the INPUT volume root"
    echo "WARNING: instead - it is then carried through the generation unchanged."
fi

#Drop only the artifacts THIS library produced in an earlier run, so a changed <version> (or
#<artifactId>) does not leave a stale jar behind for a consumer that globs target/*.jar. A
#client's own build output in target/ is untouched.
rm -f "${OUTPUT_VOLUME_FS:?}/target/${MAVEN_ARTIFACT_ID}"-*.jar

echo "Copying output files to mounted directory"
cp -r "$MAVEN_PROJECT_DIR"/lib/* "$OUTPUT_VOLUME_FS" || { echo "ERROR: failed to copy library to output volume" >&2; exit 1; }
echo "Finished copying"

# -------------- END
echo ".proto to java library compilation finished successfully."
echo "A standalone maven project ($MAVEN_GROUP_ID:$MAVEN_ARTIFACT_ID:$LIBRARY_VERSION) with"
echo "pom.xml, src/main/java and target/*.jar is located in the mounted output volume."

echo "DONE: execute script compile-proto-2-java.sh"
