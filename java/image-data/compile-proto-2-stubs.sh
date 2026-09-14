#!/bin/bash
set -e

# -------------- Generate the java message + grpc service stubs with protoc
# $1 directory the generated *.java tree is written to (a java source root)
# $2 protos root directory -> protoc's single -I / import root
# $3 directory whose *.proto files are actually compiled (a sub-dir of $2, or $2 itself)
STUBS_TARGET_DIR=$1
PROTOS_ROOT_DIR=$2
PROTOS_SRC_DIR=$3

#Container default; env-overridable so the script can run (and be tested) outside the image
PROTOC_GEN_GRPC_JAVA="${PROTOC_GEN_GRPC_JAVA:-/usr/local/bin/protoc-gen-grpc-java}"

if [ -z "$STUBS_TARGET_DIR" ] || [ -z "$PROTOS_ROOT_DIR" ] || [ -z "$PROTOS_SRC_DIR" ]; then
    echo "ERROR: usage: compile-proto-2-stubs.sh <stubs_target_dir> <protos_root_dir> <protos_src_dir> - exiting" >&2
    exit 1
fi

#--java_out refuses to write into a directory that does not exist yet
echo "Make proto generation target directory: $STUBS_TARGET_DIR"
mkdir -p "$STUBS_TARGET_DIR"

#Find .protos in directory and count the occurances
echo "Checking $PROTOS_SRC_DIR for .proto files"
if [ ! -d "$PROTOS_SRC_DIR" ]; then
    echo "ERROR: No proto files were found - the protos source directory '$PROTOS_SRC_DIR' does not exist - exiting" >&2
    exit 1
fi
if [ ! -d "$PROTOS_ROOT_DIR" ]; then
    echo "ERROR: the protos root directory (protoc -I import root) '$PROTOS_ROOT_DIR' does not exist - exiting" >&2
    exit 1
fi

# -------------- Extra protoc import roots (-I) for apis that do not vendor google/ at the root
# ondewo-survey-api keeps its googleapis checkout ONE LEVEL DOWN - `googleapis/google/api/...`
# instead of the `google/api/...` that nlu/csi/vtsi carry at the protos root - so
# `import "google/api/annotations.proto";` does not resolve against `-I <protos root>` alone and
# every generation fails with "google/api/annotations.proto: File not found.". EXTRA_PROTO_DIRS is
# a space-separated list of ADDITIONAL import roots, each relative to the protos root (an absolute
# path is taken as-is) - the java analogue of python/Makefile's EXTRA_PROTO_DIR.
#
# The DEFAULT auto-detects that layout: `googleapis` exactly when the protos root carries it AND
# does not already carry `google/` itself. So every api that resolves its google imports from the
# root keeps an empty list and a byte-identical protoc command line, and a root that vendors both
# is left resolving google/* from where it always did. `${VAR-...}` (no colon) so an explicit
# EXTRA_PROTO_DIRS="" switches the auto-detection off without switching the whole knob off.
if [ -d "$PROTOS_ROOT_DIR/googleapis" ] && [ ! -d "$PROTOS_ROOT_DIR/google" ]; then
    AUTO_EXTRA_PROTO_DIRS="googleapis"
else
    AUTO_EXTRA_PROTO_DIRS=""
fi
EXTRA_PROTO_DIRS="${EXTRA_PROTO_DIRS-$AUTO_EXTRA_PROTO_DIRS}"

# The auto-detected default can only ever name a directory that exists (it is produced by a `-d`
# test), so a missing entry is always a typo in a caller's override. Refuse it here instead of
# letting protoc fail later with an unrelated "File not found" that names the import, not the
# import root. Unquoted on purpose: EXTRA_PROTO_DIRS is a space-separated LIST.
EXTRA_INCLUDE_FLAGS=""
for extra_dir in $EXTRA_PROTO_DIRS; do
    case $extra_dir in
        /*) extra_path=$extra_dir ;;
        *) extra_path=$PROTOS_ROOT_DIR/$extra_dir ;;
    esac
    if [ ! -d "$extra_path" ]; then
        echo "ERROR: the extra protoc import root '$extra_path' (EXTRA_PROTO_DIRS entry" >&2
        echo "       '$extra_dir') does not exist - exiting" >&2
        exit 1
    fi
    EXTRA_INCLUDE_FLAGS="$EXTRA_INCLUDE_FLAGS -I $extra_path"
    echo "Extra protoc import root: $extra_path"
done

# The vendored google/ tree is an IMPORT PATH, never a compilation target: its java classes
# ship in protobuf-java (google/protobuf/*) and proto-google-common-protos (google/api,
# google/rpc, google/type), both pinned in the generated pom.xml. Sweeping it in would emit
# duplicate com.google.* classes onto every consumer's classpath AND drag in the hundreds of
# vendored googleapis protos, at least one of which (grafeas.proto) has a broken import and
# aborts the whole run. `!` (not `-not`) and an explicit start path, for GNU/BSD portability.
#Matched by NAME and then filtered with `test -f` - never with find's own `-type f`. This is the
#`[ -f ]` filter angular/ and go/ apply, written in find's own syntax so that a path containing a
#newline stays a single entry instead of being re-split by a shell loop:
#  * `-type f` does not follow a symlink, and the input volume is staged with `cp -r`, which
#    keeps links verbatim - so a .proto a client symlinked into its protos dir was silently
#    dropped from the compile set (measured: find -type f returns 1 of 2). `test -f` follows it.
#  * the name alone is not enough either: a DIRECTORY named e.g. "vendor.proto" would satisfy the
#    no-protos guard below and then be handed to protoc as an input file.
#  * NOT `find -L ... -type f`: that spelling has to put the flag BEFORE the start path, which
#    the BSD-portability gate over these scripts rejects, and -L makes find DESCEND into
#    symlinked directories, where a link loop can hang the run. Plain find never descends one,
#    so a looping link is just a link that fails `test -f` and is reported by the guard below.
ALL_PROTO_FILES=$(find "$PROTOS_SRC_DIR" -iname "*.proto" ! -path "*/google/*" -exec test -f {} \; -print)
#A .proto symlink that resolves to nothing (or to a directory) drops out of the set above without
#a word - and a silently missing proto is a silently missing service in the client. `sed`+`tr`
#join the hits onto the message line exactly the way angular/ and go/ spell it.
DANGLING_PROTO_LINKS=$(find "$PROTOS_SRC_DIR" -type l -iname "*.proto" ! -path "*/google/*" -exec test ! -f {} \; -print | sed 's|^| |' | tr -d '\n')
if [ -n "$DANGLING_PROTO_LINKS" ]; then
    echo "ERROR: these .proto symlinks do not resolve to a file:$DANGLING_PROTO_LINKS" >&2
    echo "       the mounted input volume is staged with 'cp -r', which keeps symlinks verbatim, so a link that leaves that volume (an absolute path, or a relative one reaching above it) dangles in the copy - point it inside the mounted directory or materialise the file - exiting" >&2
    exit 1
fi

# `grep -c .` instead of `wc -l`: BSD wc pads its output with spaces, and grep does not miscount
# an empty variable as one line. It exits 1 on no match, hence the `|| true` under set -e.
PROTO_FILES_CNT=$(printf '%s\n' "$ALL_PROTO_FILES" | grep -c . || true)
if [ "$PROTO_FILES_CNT" -lt 1 ]; then
    echo "ERROR: No proto files were found in the '$PROTOS_SRC_DIR' directory, but are required to build a library from - exiting" >&2
    exit 1
fi
echo "Found $PROTO_FILES_CNT .proto files in directory: $PROTOS_SRC_DIR"

# Unscoped run (no target subdirectory, arg 2 of the orchestrator): the whole protos root is
# swept. That is right for a root holding a single tree - ondewo-nlu-api is `ondewo/` plus the
# always-excluded `google/`, and the example is protos at the root plus `dependency/` - but a
# root that vendors several INDEPENDENT trees (grafeas/, protoc-gen-openapiv2/, another
# client's api/) would be compiled wholesale, which emits duplicate classes and import errors.
# Refuse loudly and name the fix instead. `/\{1,\}` (portable BRE): BSD find does not collapse
# the doubled slash a trailing-slash start path produces, GNU find does.
#
# Detecting the unscoped run is a STRING comparison of two paths that name the same directory
# with a different number of trailing slashes: the orchestrator appends one to the protos root
# ('<root>/'), and a caller that already passed 'protos/' as argument 1 makes that '<root>//'.
# `${var%/}` strips exactly one of them, so both operands are trimmed of ALL trailing slashes
# here - otherwise a trailing slash on argument 1 slips silently past the guard and every
# top-level tree is compiled in one pass, which is what the guard exists to refuse.
PROTOS_SRC_DIR_TRIMMED=$(printf '%s' "$PROTOS_SRC_DIR" | sed 's|/\{1,\}$||')
PROTOS_ROOT_DIR_TRIMMED=$(printf '%s' "$PROTOS_ROOT_DIR" | sed 's|/\{1,\}$||')
if [ "$PROTOS_SRC_DIR_TRIMMED" = "$PROTOS_ROOT_DIR_TRIMMED" ]; then
    TOP_LEVEL_TREES=$(printf '%s\n' "$ALL_PROTO_FILES" \
        | sed -n "s|^$PROTOS_ROOT_DIR_TRIMMED/\{1,\}\([^/]\{1,\}\)/.*|\1|p" | sort -u)
    TOP_LEVEL_TREES_CNT=$(printf '%s\n' "$TOP_LEVEL_TREES" | grep -c . || true)
    if [ "$TOP_LEVEL_TREES_CNT" -gt 1 ]; then
        echo "ERROR: no target subdirectory was given, and the protos root '$PROTOS_ROOT_DIR'" >&2
        echo "       spans $TOP_LEVEL_TREES_CNT top-level trees:" >&2
        printf '%s\n' "$TOP_LEVEL_TREES" | sed 's|^|           |' >&2
        echo "       Compiling all of them in one pass emits duplicate classes and import errors -" >&2
        echo "       scope the compilation by passing the subdirectory to compile (e.g. 'ondewo')" >&2
        echo "       as argument 2 of compile-proto-2-java.sh - exiting" >&2
        exit 1
    fi
fi
echo "Source verified."

# -------------- Generate the proto client library stubs
echo "---------------------------------------------------------------"
echo "Java: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"
echo "Consuming .proto files: $ALL_PROTO_FILES: "

# A single protoc pass generates both the message classes (--java_out) and the service stubs
# (--grpc-java_out). Unlike nodejs/typescript there is deliberately NO second "dependency"
# pass and no proto-deps.txt: the java classes for the google/* imports come from jars.
# shellcheck disable=SC2086  # intentional word splitting of the extra -I flags and the proto file list
protoc \
    --plugin=protoc-gen-grpc-java="$PROTOC_GEN_GRPC_JAVA" \
    --java_out="$STUBS_TARGET_DIR" \
    --grpc-java_out="$STUBS_TARGET_DIR" \
    -I "$PROTOS_ROOT_DIR" \
    $EXTRA_INCLUDE_FLAGS \
    $ALL_PROTO_FILES

echo ".proto compilation finished."

#Post-condition: protoc exits 0 on an empty input set in some versions, so assert real output
JAVA_FILES_CNT=$(find "$STUBS_TARGET_DIR" -type f -iname "*.java" | grep -c . || true)
if [ "$JAVA_FILES_CNT" -lt 1 ]; then
    echo "ERROR: protoc produced no .java files in '$STUBS_TARGET_DIR' - exiting" >&2
    exit 1
fi
echo "files generated by proto compilation: $JAVA_FILES_CNT"

echo "---------------------------------------------------------------"
echo "✅ Java: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
