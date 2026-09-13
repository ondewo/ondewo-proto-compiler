#!/bin/bash
set -e

# ---------------------------------------------------------------------------------------------
# .proto -> C# stub generation.
#
#   $1 <stubs_target_dir>  directory the generated *.cs are written to
#   $2 <protos_root_dir>   the protoc `-I` root
#   $3 <protos_src_dir>    the directory that is scanned for .proto files to compile
#
# $EXTRA_PROTO_DIRS      optional, space-separated ADDITIONAL protoc `-I` roots (container paths,
#                        i.e. below /input-volume). Auto-detected when unset - see below.
#
# There is no 4th proto-deps argument (unlike the node targets): the google/api, google/rpc and
# google/type descriptors the ONDEWO protos import are supplied at build time by the
# Google.Api.CommonProtos NuGet package, so no google/* stubs are generated here.
# ---------------------------------------------------------------------------------------------

STUBS_TARGET_DIR=$1
PROTOS_ROOT_DIR=$2
PROTOS_SRC_DIR=$3

#Path of the gRPC C# codegen plugin; env-overridable so the script stays runnable (and testable)
#outside the image, where the binary does not live at its container path.
GRPC_CSHARP_PLUGIN="${GRPC_CSHARP_PLUGIN:-/usr/local/bin/grpc_csharp_plugin}"

if [ -z "$STUBS_TARGET_DIR" ] || [ -z "$PROTOS_ROOT_DIR" ] || [ -z "$PROTOS_SRC_DIR" ]; then
    echo "ERROR: usage: compile-proto-2-stubs.sh <stubs_target_dir> <protos_root_dir> <protos_src_dir> - exiting" >&2
    exit 1
fi

# -------------- Extra protoc include roots
# Space-separated list of ADDITIONAL `-I` roots, on top of the proto root itself. Needed because
# the ONDEWO APIs do not all vendor the google/* imports at the same depth: nlu/csi/vtsi/... put
# them at <protos_root>/google/..., but ondewo-survey-api vendors the whole googleapis checkout,
# so the very same `import "google/api/annotations.proto";` lives at
# <protos_root>/googleapis/google/api/annotations.proto and is unresolvable from the root alone
# ("google/api/annotations.proto: File not found."). This is the csharp analogue of the python
# target's EXTRA_PROTO_DIR (python/Makefile), which mounts that directory as a second proto dir.
#
# The default AUTO-DETECTS that layout and is deliberately conservative: it fires only when the
# root has a googleapis/ directory and NO google/ directory of its own, so the products that
# already resolve their imports from the root keep exactly the single -I they had. Env-overridable
# for a layout that is neither shape.
EXTRA_PROTO_DIRS="${EXTRA_PROTO_DIRS:-}"
if [ -z "$EXTRA_PROTO_DIRS" ] && [ -d "$PROTOS_ROOT_DIR/googleapis" ] && [ ! -d "$PROTOS_ROOT_DIR/google" ]; then
    echo "Detected a nested googleapis/ layout in '$PROTOS_ROOT_DIR' - adding it as an extra include root"
    EXTRA_PROTO_DIRS="$PROTOS_ROOT_DIR/googleapis"
fi

#Rejected early and by name: an unresolvable include root would otherwise surface as protoc's
#generic "File not found." for whatever import it was meant to satisfy.
EXTRA_INCLUDE_FLAGS=""
for EXTRA_INCLUDE_DIR in $EXTRA_PROTO_DIRS; do
    if [ ! -d "$EXTRA_INCLUDE_DIR" ]; then
        echo "ERROR: the extra proto include directory '$EXTRA_INCLUDE_DIR' does not exist - it is" >&2
        echo "       taken from EXTRA_PROTO_DIRS (a space-separated list of additional protoc -I" >&2
        echo "       roots) - exiting" >&2
        exit 1
    fi
    echo "Using extra proto include root: $EXTRA_INCLUDE_DIR"
    EXTRA_INCLUDE_FLAGS="$EXTRA_INCLUDE_FLAGS -I $EXTRA_INCLUDE_DIR"
done

echo "Make proto generation target directory: $STUBS_TARGET_DIR"
#The compile directory this writes into is a verbatim copy of the input volume, which for a C#
#client is the repository itself - so it can already carry the api/ directory of a previous run
#(directly, or copied back from a nested output volume). Left in place, a stub of a proto that no
#longer exists is picked up by the SDK's default Compile glob, ends up in the assembly and in the
#.nupkg, and a renamed message ships under both spellings. This is the api/ half of the wipe
#compile-stubs-2-lib.sh does for lib/; `${VAR:?}` so an empty value can never expand to `rm -rf /`
#(the usage guard above already rejects an empty argument).
rm -rf "${STUBS_TARGET_DIR:?}"
mkdir -p "$STUBS_TARGET_DIR"

#Find .protos in directory and count the occurances
echo "Checking $PROTOS_SRC_DIR for .proto files"
if [ ! -d "$PROTOS_SRC_DIR" ]; then
    echo "ERROR: No proto files were found - the protos source directory '$PROTOS_SRC_DIR' does not exist - exiting" >&2
    exit 1
fi
# The vendored google/ tree is an IMPORT PATH, never a compilation target: the C# types for
# google/protobuf/* ship in the Google.Protobuf package and those for google/api, google/rpc and
# google/type in Google.Api.CommonProtos, both PackageReference'd by the generated .csproj (see
# the header above). Generating them here would emit a second, colliding copy of every Google.*
# type into the assembly and drag in the hundreds of vendored googleapis protos that an unscoped
# run - the empty target subdir `make run` and the example both pass - sweeps up.
# `!` (not `-not`) and an explicit start path, for GNU/BSD portability.
#LIMITATION: `-path` matches the WHOLE path find prints, so `*/google/*` is unanchored - it also
#excludes everything below a `google` segment ABOVE the proto root. Inside the image the root is
#always $INPUT_VOLUME_FS/<relative_protos_dir>, i.e. /input-volume/..., so it can only bite a
#caller who names the proto root (or its target subdir) literally `google`, and then it excludes
#ALL protos and the guard below aborts loudly - it never silently drops a subset. Left spelled
#exactly as java/image-data/compile-proto-2-stubs.sh spells it: cross-target consistency is worth
#more here than anchoring one copy of the filter.
#`-type f` so a DIRECTORY whose name ends in .proto is neither counted as an input nor handed to
#protoc, where it would fail with protoc's "Is a directory" instead of the no-protos guard below.
ALL_PROTO_FILES=$(find "$PROTOS_SRC_DIR" -type f -iname "*.proto" ! -path "*/google/*")

# `grep -c .` instead of `wc -l`: BSD wc pads its output with spaces, and grep does not miscount
# an empty variable as one line. It exits 1 on no match, hence the `|| true` under set -e.
PROTO_FILES_CNT=$(printf '%s\n' "$ALL_PROTO_FILES" | grep -c . || true)
if [[ $PROTO_FILES_CNT -lt 1 ]]; then
    echo "ERROR: No proto files were found in the '$PROTOS_SRC_DIR' directory, but are required to build a library from - exiting"
    exit 1
fi
echo "Found $PROTO_FILES_CNT .proto files in directory: $PROTOS_SRC_DIR"
echo "Source verified."

# -------------- Generate the proto client library stubs
echo "Starting .proto to grpc client stubs compilation ..."
echo "Consuming .proto files: $ALL_PROTO_FILES: "

# --plugin=protoc-gen-grpc=<path> is mandatory and is what makes the flag spelling --grpc_out:
# the binary is called grpc_csharp_plugin, not protoc-gen-grpc.
#
# `base_namespace=` with an EMPTY value is load-bearing. It nests the output by C# namespace
# (Ondewo/Nlu/Session.cs). Without it protoc writes flat files named after the proto basename
# and two same-named protos in different packages abort the run with
# "Common.cs: Tried to write the same file twice.". Both generators accept the option; for
# --grpc_out it has to be passed in the `opts:DIR` form.
#
# google/protobuf/*.proto resolve with no extra -I (protoc looks in <bindir>/../include, which
# the Dockerfile populated from the protoc zip); google/api, google/rpc and google/type resolve
# out of the client's mounted tree via -I "$PROTOS_ROOT_DIR" - or, for a product that vendors the
# googleapis checkout instead, via the extra -I root(s) resolved above - and are compiled as
# imports only.
# shellcheck disable=SC2086  # intentional word splitting of the extra -I flags and the proto file list
protoc \
--plugin=protoc-gen-grpc="$GRPC_CSHARP_PLUGIN" \
--csharp_out="$STUBS_TARGET_DIR" \
--csharp_opt=base_namespace= \
--grpc_out=base_namespace=:"$STUBS_TARGET_DIR" \
-I "$PROTOS_ROOT_DIR" \
$EXTRA_INCLUDE_FLAGS \
$ALL_PROTO_FILES

echo ".proto compilation finished."

# --csharp_out emits exactly one <PascalCase(basename)>.cs per input proto, --grpc_out one
# <PascalCase(basename)>Grpc.cs per proto that declares at least one service - so the count is
# NOT a fixed multiple of the proto count.
#`-type f` for the same reason as the input-side find above: this is a count of generated FILES,
#and a directory whose name happens to end in .cs would otherwise inflate the number reported to
#the operator.
STUB_FILES_CNT=$(find "$STUBS_TARGET_DIR" -type f -iname "*.cs" | grep -c . || true)
echo "files generated by proto compilation: $STUB_FILES_CNT"
