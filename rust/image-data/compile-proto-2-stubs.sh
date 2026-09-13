#!/bin/bash
set -e

# ---------------------------------------------------------------------------------------
# The single protoc invocation of the rust pipeline.
#
#   compile-proto-2-stubs.sh <crate_dir> <protos_root_dir> <protos_src_dir> <manifest_template>
#
#   $1  the crate that is being assembled; stubs land in <crate_dir>/src/api, and
#       protoc-gen-prost-crate writes <crate_dir>/Cargo.toml + <crate_dir>/src/api/mod.rs
#   $2  the proto root (protoc -I); every `import "x/y.proto";` resolves against it
#   $3  the sub-directory of the proto root whose protos are the compilation entry points
#   $4  the crate manifest template handed to --prost-crate_opt=gen_crate=
# ---------------------------------------------------------------------------------------

# Pull in the transitive proto dependency resolver (a verbatim copy of the js target's):
# prost only emits a module for a package protoc was actually asked to generate, so every
# imported, non-well-known proto has to be on the command line too. google/protobuf/* is
# excluded by the resolver and stays mapped to ::prost_types.
. "$(dirname "$0")"/dependecy-resolver.sh

CRATE_DIR="$1"
PROTOS_ROOT_DIR="$2"
PROTOS_SRC_DIR="$3"
MANIFEST_TEMPLATE="$4"

#External binaries, env-overridable so the script stays drivable outside the image
PROTOC="${PROTOC:-protoc}"

if [ -z "$CRATE_DIR" ] || [ -z "$PROTOS_ROOT_DIR" ] || [ -z "$PROTOS_SRC_DIR" ] || [ -z "$MANIFEST_TEMPLATE" ]; then
    echo "ERROR: usage: compile-proto-2-stubs.sh <crate_dir> <protos_root_dir> <protos_src_dir> <manifest_template> - exiting" >&2
    exit 1
fi

#The generated module tree is confined to src/api so that the copy-back can wipe exactly it
#without touching the hand-written modules that live beside it under src/.
CRATE_API_DIR="$CRATE_DIR/src/api"

echo "Crate dir: $CRATE_DIR"
echo "Protos root dir: $PROTOS_ROOT_DIR"
echo "Protos src dir: $PROTOS_SRC_DIR"
echo "Manifest template: $MANIFEST_TEMPLATE"

# -------------- Verify the sources
if [ ! -d "$PROTOS_ROOT_DIR" ]; then
    echo "ERROR: No proto files were found - the protos root directory '$PROTOS_ROOT_DIR' does not exist - exiting" >&2
    exit 1
fi
if [ ! -d "$PROTOS_SRC_DIR" ]; then
    echo "ERROR: No proto files were found - the protos source directory '$PROTOS_SRC_DIR' does not exist - exiting" >&2
    exit 1
fi
if [ ! -f "$MANIFEST_TEMPLATE" ]; then
    echo "ERROR: The crate manifest template '$MANIFEST_TEMPLATE' does not exist - exiting" >&2
    exit 1
fi

#Find .protos in directory and count the occurances.
#`-type f` matters: a DIRECTORY named e.g. "dir.protos" would otherwise satisfy the guard
#and hand protoc a directory as an input file.
#google/protobuf/* is filtered out for the same reason the dependency resolver excludes it
#from the IMPORT side: those types stay mapped to ::prost_types, and compiling a vendored
#copy would emit a second, duplicate `google.protobuf` module into the crate. `|| true`
#keeps `set -e` happy when grep filters everything away - the empty-list guard below reports
#that far more descriptively.
echo "Checking $PROTOS_SRC_DIR for .proto files"
ENTRY_PROTO_FILES=$(find "$PROTOS_SRC_DIR" -type f -iname "*.proto" | grep -v '/google/protobuf/' || true)
if [ -z "$ENTRY_PROTO_FILES" ]; then
    echo "ERROR: No proto files were found in the '$PROTOS_SRC_DIR' directory, but are required to build a library from - exiting" >&2
    exit 1
fi
PROTO_FILES_CNT=$(printf '%s\n' "$ENTRY_PROTO_FILES" | grep -c . || true)
echo "Found $PROTO_FILES_CNT .proto files in directory: $PROTOS_SRC_DIR"
echo "Source verified."

# -------------- Resolve the transitive, proto-root-relative, de-duplicated file list
if ! ALL_PROTO_FILES=$(echoProtoDependencies "$PROTOS_ROOT_DIR" "$ENTRY_PROTO_FILES"); then
    echo "ERROR: proto dependency resolution failed - exiting" >&2
    exit 1
fi
ALL_PROTO_FILES=$(printf '%s\n' "$ALL_PROTO_FILES" | sort -u | tr "\n" " ")
# tr -d strips BSD/macOS wc's leading-space field padding (GNU wc emits a bare count)
ALL_PROTO_FILES_CNT=$(echo "$ALL_PROTO_FILES" | wc -w | tr -d ' ')

# -------------- Pre-flight: every compiled proto must declare a package.
# protoc-gen-prost-crate's include-file generator computes `next.len() - prefix - 1` and then
# calls `next.parts().last().unwrap()`; for the 0-part root module of a package-less proto
# that underflows and panics, and protoc only reports an opaque "plugin failed". Catch it
# here with a message that names the offending file.
# shellcheck disable=SC2086  # intentional word splitting of proto file list
for protofile in $ALL_PROTO_FILES; do
    if [ ! -f "$PROTOS_ROOT_DIR/$protofile" ]; then
        echo "ERROR: the resolved proto '$protofile' does not exist under the protos root '$PROTOS_ROOT_DIR' - exiting" >&2
        exit 1
    fi
    if ! grep -q '^[[:space:]]*package[[:space:]]' "$PROTOS_ROOT_DIR/$protofile"; then
        echo "ERROR: '$protofile' declares no 'package' - prost cannot place it in the crate module tree - exiting" >&2
        exit 1
    fi
done

# -------------- Prepare the output directories.
# protoc refuses an --X_out whose directory does not exist (VerifyDirectoryExists), and
# --prost-crate_out writes src/api/mod.rs + Cargo.toml relative to $CRATE_DIR, so both
# $CRATE_DIR and $CRATE_API_DIR have to pre-exist.
mkdir -p "$CRATE_DIR" "$CRATE_API_DIR"

# protoc-gen-prost-crate opens gen_crate= with a bare relative fs::open from protoc's
# inherited CWD, and we cd into the proto root below - so canonicalise the template to an
# absolute path first, and reject a comma in it (protoc joins all --prost-crate_opt params
# with commas before handing them to the plugin as a single string).
MANIFEST_TEMPLATE="$(cd "$(dirname "$MANIFEST_TEMPLATE")" && pwd)/$(basename "$MANIFEST_TEMPLATE")"
case "$MANIFEST_TEMPLATE" in
    *,*)
        echo "ERROR: the manifest template path contains a comma, which protoc uses as the plugin-option separator: '$MANIFEST_TEMPLATE' - exiting" >&2
        exit 1
        ;;
esac
#Same for the api dir: it is spelled into --prost-crate_opt=include_file=... only as a
#relative path, but --prost_out / --tonic_out take it verbatim and must be absolute.
CRATE_API_DIR="$(cd "$CRATE_API_DIR" && pwd)"

# -------------- Generate the proto client library stubs
echo "Starting .proto to grpc client stubs compilation ..."
echo "Consuming $ALL_PROTO_FILES_CNT .proto files: $ALL_PROTO_FILES ... "

CWD=$(pwd)
cd "$PROTOS_ROOT_DIR" || exit 1

# All three plugins MUST run in ONE protoc invocation, with --prost_out FIRST and
# --tonic_out naming the SAME lexical directory: protoc-gen-tonic does not write a
# standalone file, it returns a response with insertion_point "module" targeting the
# <package>.rs that protoc-gen-prost wrote, and protoc resolves that only against the
# in-memory file set of the GeneratorContext the two share - one context per output
# location, normalised for a trailing slash only. Splitting this into two calls fails with
# "Tried to write insertion point ... which doesn't exist"; reordering silently drops every
# gRPC client. This is also why the resolved google/ dependencies go through this same
# invocation instead of a second pass (a second pass would regenerate src/api/mod.rs and
# Cargo.toml from the dependency set alone and clobber the real barrel).
#
# flat_output_dir on all three keeps every module in a single "<proto.package>.rs" file:
# without it the module path becomes a directory path and package `google.type` yields a
# directory literally named `r#type` (prost escapes the Rust keyword).
# no_features keeps the manifest template verbatim; no compile_well_known_types so that
# google.protobuf.* keeps mapping to ::prost_types.
# shellcheck disable=SC2086  # intentional word splitting of proto file list
"$PROTOC" \
-I "$PROTOS_ROOT_DIR" \
--prost_out="$CRATE_API_DIR" \
--prost_opt=flat_output_dir \
--tonic_out="$CRATE_API_DIR" \
--tonic_opt=flat_output_dir \
--prost-crate_out="$CRATE_DIR" \
--prost-crate_opt=flat_output_dir,no_features,include_file=src/api/mod.rs,gen_crate="$MANIFEST_TEMPLATE" \
$ALL_PROTO_FILES

cd "$CWD" || exit 1

echo ".proto compilation finished."

# -------------- Fail loudly rather than ship a crate whose barrel references files protoc
# never wrote (a plugin that silently did not run leaves exactly that behind).
if [ ! -f "$CRATE_API_DIR/mod.rs" ]; then
    echo "ERROR: protoc produced no 'src/api/mod.rs' - the prost-crate plugin did not run - exiting" >&2
    exit 1
fi
if [ ! -f "$CRATE_DIR/Cargo.toml" ]; then
    echo "ERROR: protoc produced no 'Cargo.toml' from gen_crate=$MANIFEST_TEMPLATE - exiting" >&2
    exit 1
fi

STUB_FILES_CNT=$(find "$CRATE_API_DIR" -type f -name "*.rs" | grep -c . || true)
echo "files generated by proto compilation: $STUB_FILES_CNT"
