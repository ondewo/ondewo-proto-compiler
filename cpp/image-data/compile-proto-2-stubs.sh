#!/bin/bash
set -e

# shellcheck source-path=SCRIPTDIR
# shellcheck source=dependecy-resolver.sh
. "$(dirname "$0")"/dependecy-resolver.sh

# -------------- Positional arguments
# $1 <stubs_target_dir> : where the generated stubs are written (absolute - this script cd's away)
# $2 <protos_root_dir>  : the protoc include root; generated paths are relative to it
# $3 <protos_src_dir>   : the sub-tree whose protos are the entry points of the import closure
STUBS_TARGET_DIR="$1"
PROTOS_ROOT_DIR="$2"
PROTOS_SRC_DIR="$3"

echo "Stubs target dir: $STUBS_TARGET_DIR"
echo "Protos root dir: $PROTOS_ROOT_DIR"
echo "Protos src dir: $PROTOS_SRC_DIR"

if [ -z "$STUBS_TARGET_DIR" ] || [ -z "$PROTOS_ROOT_DIR" ] || [ -z "$PROTOS_SRC_DIR" ]; then
    echo "ERROR: usage: compile-proto-2-stubs.sh <stubs_target_dir> <protos_root_dir> <protos_src_dir> - exiting" >&2
    exit 1
fi

#Env-overridable so the bats suite can point it at a PATH mock; /usr/bin/grpc_cpp_plugin is where
#Debian's protobuf-compiler-grpc installs it (the Dockerfile also sets it as an ENV default).
GRPC_CPP_PLUGIN="${GRPC_CPP_PLUGIN:-/usr/bin/grpc_cpp_plugin}"
command -v "$GRPC_CPP_PLUGIN" >/dev/null 2>&1 || {
    echo "ERROR: grpc_cpp_plugin not found at '$GRPC_CPP_PLUGIN' - the gRPC service stubs cannot be generated; is protobuf-compiler-grpc installed? - exiting" >&2
    exit 1
}

if [ ! -d "$PROTOS_ROOT_DIR" ]; then
    echo "ERROR: the protos root directory '$PROTOS_ROOT_DIR' does not exist - check the <relative_protos_dir> argument against the contents of the input volume - exiting" >&2
    exit 1
fi

#Find .protos in directory and count the occurances
echo "Checking $PROTOS_SRC_DIR for .proto files"

if [ ! -d "$PROTOS_SRC_DIR" ]; then
    echo "ERROR: No proto files were found - the protos source directory '$PROTOS_SRC_DIR' does not exist - exiting" >&2
    exit 1
fi
#`-type f` matters: a DIRECTORY named e.g. "session.proto" would otherwise satisfy the guard
#below and then be handed to protoc as an input file, replacing this script's own diagnosis with
#an opaque "Missing input file." from protoc.
#google/protobuf/** is filtered out for the same reason echoProtoDependencies excludes it on the
#IMPORT side: those types are already compiled into libprotobuf, so a client that vendors a copy
#under its proto root would get them compiled into the archive too and the link would fail on
#duplicate symbols. The import-side exclusion alone does not cover this - a vendored well-known
#type under the compiled sub-tree is an ENTRY proto, which never passes through that filter.
#`|| true` keeps `set -e` happy when the filter empties the list - the guard below reports that
#far more descriptively.
ENTRY_PROTO_FILES=$(find "$PROTOS_SRC_DIR" -type f -iname "*.proto" | grep -v '/google/protobuf/' || true)
#`grep -c . || true` instead of `wc -l`: BSD/macOS wc pads its output with spaces, and grep -c
#exits 1 on an empty list, which must not abort the script before the guard below reports it
PROTO_FILES_CNT=$(printf '%s\n' "$ENTRY_PROTO_FILES" | grep -c . || true)
if [ "$PROTO_FILES_CNT" -lt 1 ]; then
    echo "ERROR: No proto files were found in the '$PROTOS_SRC_DIR' directory, but are required to build a library from - exiting" >&2
    exit 1
fi
echo "Found $PROTO_FILES_CNT .proto files in directory: $PROTOS_SRC_DIR"
echo "Source verified."

# -------------- Resolve the transitive import closure
#Compile the entry protos PLUS everything they import, EXCLUDING google/protobuf/** (hardcoded in
#echoProtoDependencies for the imports, applied to the entry list above). Both halves matter for
#C++:
#  - the well-known types are already compiled into libprotobuf, so generating and compiling them
#    again duplicates symbols and breaks the link;
#  - resolving the closure instead of globbing the whole proto root is what keeps the build small.
#    ondewo-nlu-api ships 435 protos under google/; the closure prunes them to a handful, so the
#    C++ build is ~50 translation units instead of thousands. Do NOT "simplify" this into a
#    `find "$PROTOS_ROOT_DIR" -name '*.proto'` glob - that is the obvious-looking change and it
#    breaks the build in both of those ways at once.
if ! ALL_PROTO_FILES=$(echoProtoDependencies "$PROTOS_ROOT_DIR" "$ENTRY_PROTO_FILES"); then
    echo "ERROR: proto dependency resolution failed - an import above could not be resolved under the proto root '$PROTOS_ROOT_DIR'; is the proto submodule complete? - exiting" >&2
    exit 1
fi
ALL_PROTO_FILES=$(printf '%s\n' "$ALL_PROTO_FILES" | sort -u | tr "\n" " ")
ALL_PROTO_FILES_CNT=$(printf '%s\n' "$ALL_PROTO_FILES" | tr " " "\n" | grep -c . || true)

# -------------- Generate the proto client library stubs
echo "Starting .proto to grpc client stubs compilation ..."
echo "Consuming $ALL_PROTO_FILES_CNT .proto files (entry protos + their transitive imports)"
printf "Files to compile: \n%s\n\n" "$ALL_PROTO_FILES"

mkdir -p "$STUBS_TARGET_DIR"

CWD=$(pwd)
#cd into the proto root so the file list is root-relative: that is what makes protoc mirror the
#proto package path into the output tree (ondewo/nlu/agent.proto -> api/ondewo/nlu/agent.pb.h),
#which in turn matches the root-relative #include lines protoc writes into the stubs themselves.
cd "$PROTOS_ROOT_DIR" || exit 1

#--cpp_out  -> <name>.pb.h + <name>.pb.cc            (built into protoc)
#--grpc_out -> <name>.grpc.pb.h + <name>.grpc.pb.cc  (grpc_cpp_plugin, bound to the reserved
#              plugin name protoc-gen-grpc via --plugin=). Emitted for service-less protos too.
#No --experimental_allow_proto3_optional: explicit presence has been stable since protobuf 3.15
#and survives natively in C++ (has_x()/clear_x()), so no Angular-style presence codemod is needed.
#protoc creates the nested output directories itself; only $STUBS_TARGET_DIR has to exist.
# shellcheck disable=SC2086  # intentional word splitting of proto file list
protoc \
--cpp_out="$STUBS_TARGET_DIR" \
--grpc_out="$STUBS_TARGET_DIR" \
--plugin=protoc-gen-grpc="$GRPC_CPP_PLUGIN" \
-I "$PROTOS_ROOT_DIR" \
$ALL_PROTO_FILES

cd "$CWD" || exit 1

echo ".proto compilation finished."

#`-type f` for the same reason as the entry-proto scan above: a DIRECTORY named "*.pb.cc" must
#not pass this post-generation guard off as a generated source.
STUB_FILES_CNT=$(find "$STUBS_TARGET_DIR" -type f -iname "*.pb.cc" | grep -c . || true)
echo "files generated by proto compilation: $STUB_FILES_CNT"
if [ "$STUB_FILES_CNT" -lt 1 ]; then
    echo "ERROR: protoc reported success but produced no '*.pb.cc' sources in '$STUBS_TARGET_DIR' - there is nothing to build a library from - exiting" >&2
    exit 1
fi
