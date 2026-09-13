#!/bin/bash
set -e

echo "START: execute script compile-proto-2-cpp.sh"

# -------------- Positional arguments
# $1 <relative_protos_dir> : proto root INSIDE the input volume         (default "protos")
# $2 <target_subdir>       : sub-directory of the proto root to compile (default: the whole root)
# $3 <library_name>        : CMake target / package / archive name      (default "ondewo_grpc_client")
#
# Arguments 1 and 2 mean exactly what they mean for nodejs/typescript, so a client's `docker run`
# line keeps the familiar shape. Argument 3 is the one C++-specific addition: unlike npm there is
# no package.json to read a library name from, so it arrives positionally (js already does this).

#Root path of all the protos to be compiled
RELATIVE_PROTOS_DIR=$1
if [ -z "$1" ]; then
    RELATIVE_PROTOS_DIR="protos"
fi

#Name of the produced CMake target / package / static archive
LIBRARY_NAME=$3
if [ -z "$3" ]; then
    LIBRARY_NAME="ondewo_grpc_client"
fi

#The library name flows straight into `cmake -DONDEWO_LIBRARY_NAME=`, then into project() and
#add_library(). Validate it HERE rather than letting CMake fail with a wall of output minutes
#into the run, after the whole input copy and the full protoc pass have already happened.
case "$LIBRARY_NAME" in
    *[!A-Za-z0-9_-]*|'')
        echo "ERROR: library name '$LIBRARY_NAME' is not a valid CMake target name - use only letters, digits, '_' and '-' (e.g. ondewo_nlu_client) - exiting" >&2
        exit 1
        ;;
esac

#"api" is this target's own name: the stubs are generated into <scratch>/api, any api/ carried in
#from the input volume is wiped before that, and the copy-back wipes <output volume>/api. A proto
#root at api/ - or anywhere below it - therefore gets deleted by this script's own scratch cleanup
#and is then reported as "the protos root directory does not exist", which diagnoses the wrong
#thing; and it could not be supported anyway, because a client whose output volume is its repo root
#would have its .proto tree deleted by the copy-back. Say what is actually wrong, up front, before
#a single file has been copied or removed.
#Leading './' and trailing '/' are stripped so 'api', './api' and 'api/' are all recognised.
NORMALISED_PROTOS_DIR="$RELATIVE_PROTOS_DIR"
while [ "${NORMALISED_PROTOS_DIR#./}" != "$NORMALISED_PROTOS_DIR" ]; do
    NORMALISED_PROTOS_DIR="${NORMALISED_PROTOS_DIR#./}"
done
while [ "${NORMALISED_PROTOS_DIR%/}" != "$NORMALISED_PROTOS_DIR" ]; do
    NORMALISED_PROTOS_DIR="${NORMALISED_PROTOS_DIR%/}"
done
case "$NORMALISED_PROTOS_DIR" in
    api|api/*)
        echo "ERROR: the protos root '$RELATIVE_PROTOS_DIR' collides with 'api/', the directory this compiler generates the stubs into and overwrites in the output volume - move the .proto tree elsewhere (e.g. 'protos/') and pass that as <relative_protos_dir> - exiting" >&2
        exit 1
        ;;
esac

#Container defaults; env-overridable so the script can run (and be tested) outside the image
IMAGE_DATA_DIRECTORY="${IMAGE_DATA_DIRECTORY:-/image-data}"
DEFAULT_FILES_DIR="$IMAGE_DATA_DIRECTORY/default-lib-files"
TEMP_SRC_DIRECTORY="${TEMP_SRC_DIRECTORY:-$IMAGE_DATA_DIRECTORY/src}"

#The CMake build and install trees live OUTSIDE the copied source tree on purpose:
#$TEMP_SRC_DIRECTORY is a verbatim copy of the input volume, so a client that keeps generated
#output in its own src/lib/ would otherwise have CMAKE_INSTALL_PREFIX point straight into it and
#its pre-existing files would be copied back out as if this run had produced them.
#Exported so compile-stubs-2-lib.sh resolves the very same directories.
BUILD_DIRECTORY="${BUILD_DIRECTORY:-$IMAGE_DATA_DIRECTORY/build}"
INSTALL_DIRECTORY="${INSTALL_DIRECTORY:-$IMAGE_DATA_DIRECTORY/install}"
export BUILD_DIRECTORY INSTALL_DIRECTORY

#Input volumes mouted at root
INPUT_VOLUME_FS="${INPUT_VOLUME_FS:-/input-volume}"
OUTPUT_VOLUME_FS="${OUTPUT_VOLUME_FS:-/output-volume}"

echo "Protos root (relative to the input volume): $RELATIVE_PROTOS_DIR"
echo "Library name: $LIBRARY_NAME"

if [ ! -d "$INPUT_VOLUME_FS" ]; then
    echo "ERROR: the input volume '$INPUT_VOLUME_FS' does not exist - mount the directory holding the .proto tree with '-v <dir>:/input-volume' - exiting" >&2
    exit 1
fi

if [ ! -d "$DEFAULT_FILES_DIR" ]; then
    echo "ERROR: the default library files directory '$DEFAULT_FILES_DIR' does not exist - is IMAGE_DATA_DIRECTORY ('$IMAGE_DATA_DIRECTORY') pointing at the image-data tree? - exiting" >&2
    exit 1
fi

#Copy source-volume contents to a scratch directory (to not modify the original files during
#compilation). Wiped first so a re-used image-data tree cannot leak a previous run's files into
#this one. Guarded with :? so an empty variable can never turn this into `rm -rf /`.
rm -rf "${TEMP_SRC_DIRECTORY:?}"
mkdir -p "$TEMP_SRC_DIRECTORY"
cp -r "$INPUT_VOLUME_FS"/* "$TEMP_SRC_DIRECTORY" || { echo "ERROR: failed to copy the contents of the input volume '$INPUT_VOLUME_FS' to '$TEMP_SRC_DIRECTORY' - is the volume empty? - exiting" >&2; exit 1; }

#An api/ directory carried in from the input volume (a client keeping its generated output in
#src/api/, i.e. every second run) would be swept into the archive by the CMakeLists'
#file(GLOB_RECURSE api/*.pb.cc). Only THIS run's stubs may be compiled. A proto root at api/ would
#be destroyed here - that case is rejected by the collision guard above, never silently wiped.
rm -rf "${TEMP_SRC_DIRECTORY:?}/api"

#Everything is compiled inside the scratch copy, the proto root included, so the mounted input
#volume is provably never written to - only the output volume is.
PROTOS_ROOT_PATH="$TEMP_SRC_DIRECTORY/$RELATIVE_PROTOS_DIR"

#If not specified take all protos in the protos root path (otherwise a relative directory)
#Subdir of the protos to be compiled
COMPILE_SELECTED_PROTOS_DIR="$PROTOS_ROOT_PATH/$2"
if [ -z "$2" ]; then
    COMPILE_SELECTED_PROTOS_DIR="$PROTOS_ROOT_PATH/"
fi
echo "Compiling protos from: $COMPILE_SELECTED_PROTOS_DIR"

#Create lib dir for output if no output volume was mounted
if [ ! -d "$OUTPUT_VOLUME_FS" ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUT_VOLUME_FS="$INPUT_VOLUME_FS/lib"
    mkdir -p "$OUTPUT_VOLUME_FS"
fi

# -------------- Check if all the requirements are there and exit if not
echo "Checking if all the source requirements are fulfilled ..."

#Nothing from the input volume is REQUIRED: unlike the node targets C++ has no package manifest a
#client must supply. The two build files are optional-with-default.
#public-api.h is deliberately NOT seeded here - make-lib-entry-point.sh owns it end to end (seed
#AND append behind one guard, like every sibling target). Seeding it here would make that guard
#false and silently ship an umbrella header that includes nothing.
for build_file in CMakeLists.txt ondewo-client-config.cmake.in; do
    if [ ! -f "$TEMP_SRC_DIRECTORY/$build_file" ]; then
        echo "No $build_file specified in source directory -> copying default file"
        cp "$DEFAULT_FILES_DIR/$build_file" "$TEMP_SRC_DIRECTORY/$build_file" || { echo "ERROR: failed to copy the default '$build_file' from '$DEFAULT_FILES_DIR' - exiting" >&2; exit 1; }
    fi
done

# -------------- Running compilation steps
echo "START: Executing \"compile-proto-2-stubs.sh\"..."
bash ./compile-proto-2-stubs.sh "$TEMP_SRC_DIRECTORY/api" "$PROTOS_ROOT_PATH" "$COMPILE_SELECTED_PROTOS_DIR" || { echo "ERROR: compile-proto-2-stubs.sh failed" >&2; exit 1; }
echo "DONE: Executing \"compile-proto-2-stubs.sh\""

echo "START: Executing \"make-lib-entry-point.sh\"..."
bash ./make-lib-entry-point.sh "$TEMP_SRC_DIRECTORY" || { echo "ERROR: make-lib-entry-point.sh failed" >&2; exit 1; }
echo "DONE: Executing \"make-lib-entry-point.sh\""

echo "START: Executing \"compile-stubs-2-lib.sh\"..."
bash ./compile-stubs-2-lib.sh "$TEMP_SRC_DIRECTORY" "$LIBRARY_NAME" || { echo "ERROR: compile-stubs-2-lib.sh failed" >&2; exit 1; }
echo "DONE: Executing \"compile-stubs-2-lib.sh\""

# -------------- Copy results back to mounted directory
echo "Copying output files to mounted directory"

if [ ! -d "$INSTALL_DIRECTORY" ]; then
    echo "ERROR: the CMake install tree '$INSTALL_DIRECTORY' does not exist - compile-stubs-2-lib.sh produced nothing to copy back - exiting" >&2
    exit 1
fi
#`grep -c . || true` instead of `wc -l`: BSD/macOS wc pads its output with spaces
INSTALLED_FILES_CNT=$(find "$INSTALL_DIRECTORY" -type f | grep -c . || true)
if [ "$INSTALLED_FILES_CNT" -lt 1 ]; then
    echo "ERROR: the CMake install tree '$INSTALL_DIRECTORY' is empty - the 'cmake --install' step installed no files - exiting" >&2
    exit 1
fi

#Remove only what THIS target owns, so an output volume pointed at a real client repo root is not
#collaterally damaged (angular's blanket wipe would eat a C++ client's hand-written lib/ and
#include/), while headers of protos that were renamed or deleted at source do not survive.
rm -rf "${OUTPUT_VOLUME_FS:?}/api"
rm -rf "${OUTPUT_VOLUME_FS:?}/include/${LIBRARY_NAME:?}"
rm -rf "${OUTPUT_VOLUME_FS:?}/lib/cmake/${LIBRARY_NAME:?}"
rm -f "${OUTPUT_VOLUME_FS:?}/lib/lib${LIBRARY_NAME:?}.a"

#The CMake install tree: include/<library_name>/ (public headers) + lib/ (archive + cmake package)
cp -r "$INSTALL_DIRECTORY"/* "$OUTPUT_VOLUME_FS" || { echo "ERROR: failed to copy the CMake install tree '$INSTALL_DIRECTORY' to the output volume '$OUTPUT_VOLUME_FS' - exiting" >&2; exit 1; }

#The generated stub SOURCES, so a consumer whose toolchain differs from this image's can rebuild
cp -r "$TEMP_SRC_DIRECTORY/api" "$OUTPUT_VOLUME_FS/api" || { echo "ERROR: failed to copy the generated stubs to '$OUTPUT_VOLUME_FS/api' - exiting" >&2; exit 1; }

#The umbrella header is wholly generated -> safe to overwrite unconditionally
cp "$TEMP_SRC_DIRECTORY/public-api.h" "$OUTPUT_VOLUME_FS/public-api.h" || { echo "ERROR: failed to copy 'public-api.h' to the output volume '$OUTPUT_VOLUME_FS' - exiting" >&2; exit 1; }

#The build files are NOT: /output-volume is typically the client's repo root, and a C++ repo's
#top-level CMakeLists.txt is the single most likely hand-written file in it. Never clobber one -
#write the generated copy next to the stubs instead so the client can diff and adopt it.
for build_file in CMakeLists.txt ondewo-client-config.cmake.in; do
    if [ -f "$OUTPUT_VOLUME_FS/$build_file" ]; then
        echo "NOTE: '$OUTPUT_VOLUME_FS/$build_file' already exists -> keeping the client's own file (the one used for this build is written to 'api/$build_file.generated')"
        cp "$TEMP_SRC_DIRECTORY/$build_file" "$OUTPUT_VOLUME_FS/api/$build_file.generated" || { echo "ERROR: failed to copy '$build_file' to '$OUTPUT_VOLUME_FS/api/$build_file.generated' - exiting" >&2; exit 1; }
    else
        cp "$TEMP_SRC_DIRECTORY/$build_file" "$OUTPUT_VOLUME_FS/$build_file" || { echo "ERROR: failed to copy '$build_file' to the output volume '$OUTPUT_VOLUME_FS' - exiting" >&2; exit 1; }
    fi
done
echo "Finished copying"

# -------------- END
echo "---------------------------------------------------------------"
echo "✅ C++: .proto to cpp library compilation finished successfully"
echo "---------------------------------------------------------------"
echo "Output in the mounted volume '$OUTPUT_VOLUME_FS':"
echo "  api/ -> the generated stub sources (*.pb.h/.cc, *.grpc.pb.h/.cc)"
echo "  CMakeLists.txt + ondewo-client-config.cmake.in -> rebuild the library from those sources"
echo "  public-api.h -> umbrella header including every generated header"
echo "  include/$LIBRARY_NAME/ -> the installed public headers"
echo "  lib/lib$LIBRARY_NAME.a -> the built static library"
echo "  lib/cmake/$LIBRARY_NAME/ -> the CMake package; consume it with"
echo "       find_package($LIBRARY_NAME CONFIG REQUIRED)"
echo "       target_link_libraries(my_app PRIVATE ondewo::$LIBRARY_NAME)"
echo "---------------------------------------------------------------"

echo "DONE: execute script compile-proto-2-cpp.sh"
