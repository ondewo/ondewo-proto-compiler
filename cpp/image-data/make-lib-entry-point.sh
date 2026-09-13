#!/bin/bash
set -e

# -------------- Create public-api.h, the umbrella header a consumer includes to get every
# generated message and service stub in one line. This is the C++ equivalent of the node targets'
# public-api.d.ts / public-api.js barrel.
#
# Seed AND append live behind ONE guard, exactly like every sibling target: a public-api.h shipped
# in the mounted input volume takes the file over completely and nothing is appended.
# Correspondingly, compile-proto-2-cpp.sh must NOT pre-seed this file - if it did, the guard below
# would be false and the shipped umbrella header would silently include nothing.
#
# C++ needs no duplicate-symbol disambiguation block (the node barrels do, because a name reachable
# through two `export *` lines is ambiguous - TS2308): proto packages become real C++ namespaces,
# so ondewo::nlu::ReasoningEffort and ondewo::s2t::ReasoningEffort simply never collide.

#Root directory of the compilation (public-api.h lands here, the generated stubs are in ./api)
TEMP_SRC_DIRECTORY=$1
if [ -z "$1" ]; then
    echo "ERROR: no source directory given - usage: make-lib-entry-point.sh <src_directory> - exiting" >&2
    exit 1
fi
if [ ! -d "$TEMP_SRC_DIRECTORY" ]; then
    echo "ERROR: the source directory '$TEMP_SRC_DIRECTORY' does not exist - exiting" >&2
    exit 1
fi

#Resolve the seed file relative to THIS script, never to the caller's working directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_FILES_DIR="${DEFAULT_FILES_DIR:-$SCRIPT_DIR/default-lib-files}"

#Can also be specified in the provided directory -> no auto generation
PUBLIC_API_FILE="$TEMP_SRC_DIRECTORY/public-api.h"

if [ -f "$PUBLIC_API_FILE" ]; then
    echo "public-api.h specified in source directory -> using it verbatim, nothing appended"
    exit 0
fi

echo "No public-api.h specified in source directory -> copying default file"
if [ ! -f "$DEFAULT_FILES_DIR/public-api.h" ]; then
    echo "ERROR: the default seed '$DEFAULT_FILES_DIR/public-api.h' does not exist - exiting" >&2
    exit 1
fi
cp "$DEFAULT_FILES_DIR/public-api.h" "$PUBLIC_API_FILE" || { echo "ERROR: failed to copy the default 'public-api.h' from '$DEFAULT_FILES_DIR' - exiting" >&2; exit 1; }

# Trying to auto generate the public-api file
cd "$TEMP_SRC_DIRECTORY" || exit 1

if [ ! -d api ]; then
    echo "ERROR: no 'api' directory in '$TEMP_SRC_DIRECTORY' - the .proto compilation step produced no stubs for the umbrella header to include - exiting" >&2
    exit 1
fi

#protoc emits <name>.pb.h and grpc_cpp_plugin emits <name>.grpc.pb.h; both match *.pb.h.
#`-type f` matters more here than anywhere else in this target: a DIRECTORY named e.g.
#"session.pb.h" would otherwise be appended as `#include "session.pb.h"` without any complaint -
#a broken umbrella header that only fails much later, in the CONSUMER's compiler.
#Sorted so two runs over the same protos produce a byte-identical header.
GENERATED_HEADERS=$(find api -type f -name "*.pb.h" | sort)
#`grep -c . || true` instead of `wc -l`: BSD/macOS wc pads its output with spaces
HEADERS_CNT=$(printf '%s\n' "$GENERATED_HEADERS" | grep -c . || true)
if [ "$HEADERS_CNT" -lt 1 ]; then
    echo "ERROR: no generated '*.pb.h' headers found under '$TEMP_SRC_DIRECTORY/api' - there is nothing for the umbrella header to include - exiting" >&2
    exit 1
fi

#The leading "api/" is stripped because api/ IS the include root of the generated library, so these
#lines resolve exactly like the root-relative includes the stubs already use on each other.
printf '%s\n' "$GENERATED_HEADERS" | sed 's|^api/||' | while IFS= read -r header; do
    printf '#include "%s"\n' "$header" >> "$PUBLIC_API_FILE"
done

echo "Generated public-api.h with $HEADERS_CNT includes"
