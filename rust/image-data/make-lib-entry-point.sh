#!/bin/bash
set -e

# ---------------------------------------------------------------------------------------
# Create src/lib.rs - the crate barrel - from the generated stub tree.
#
#   make-lib-entry-point.sh <crate_dir>
#
# Only the proto stubs are generated. Anything a client hand-writes beside them (the
# Keycloak/bearer auth surface, ...) is compiled into the crate but UNREACHABLE from
# outside it unless the barrel declares it, so every hand-written module sitting directly
# under src/ gets a `pub mod <name>;` line here.
#
# Runs AFTER compile-proto-2-stubs.sh, so src/api already exists; `pub mod api;` itself is
# part of the default barrel header in default-lib-files/lib.rs.
# ---------------------------------------------------------------------------------------

#Root directory of the crate (-> src/lib.rs in this directory + generated stubs in src/api)
CRATE_DIRECTORY=$1

#Resolve the default files relative to THIS script, never to the caller's CWD
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_FILES_DIR="${DEFAULT_FILES_DIR:-$SCRIPT_DIR/default-lib-files}"

if [ -z "$CRATE_DIRECTORY" ]; then
    echo "ERROR: usage: make-lib-entry-point.sh <crate_dir> - exiting" >&2
    exit 1
fi
if [ ! -d "$CRATE_DIRECTORY/src" ]; then
    echo "ERROR: the crate source directory '$CRATE_DIRECTORY/src' does not exist - exiting" >&2
    exit 1
fi

#Can also be specified in the provided directory -> no auto generation
LIB_ENTRY_FILE=$CRATE_DIRECTORY/src/lib.rs

if [ -f "$LIB_ENTRY_FILE" ]; then
    echo "src/lib.rs specified in source directory -> leaving it untouched"
    exit 0
fi

if [ ! -f "$DEFAULT_FILES_DIR/lib.rs" ]; then
    echo "ERROR: the default barrel '$DEFAULT_FILES_DIR/lib.rs' does not exist - the image is incomplete - exiting" >&2
    exit 1
fi

echo "No src/lib.rs specified in source directory -> copying default file"
cp "$DEFAULT_FILES_DIR/lib.rs" "$LIB_ENTRY_FILE" || { echo "ERROR: failed to copy the default src/lib.rs" >&2; exit 1; }

# -------------- Declare every hand-written module beside the generated api/ tree.
# A rust module under src/ is either "<name>.rs" or a "<name>/" directory carrying a mod.rs;
# everything else (a bare data directory, a file with an unusable name) is reported and
# skipped rather than turned into a `pub mod` line that would not compile.
# `sort` keeps the barrel byte-identical across runs; the loop runs in a subshell of the
# pipeline, which is fine because it only appends to a file.
find "$CRATE_DIRECTORY/src" -mindepth 1 -maxdepth 1 \( -type f -name "*.rs" -o -type d \) | sort | while IFS= read -r entry; do
    module_name=$(basename "$entry")
    module_name=${module_name%.rs}

    case "$module_name" in
        #api is declared by the default barrel header; lib/main are the crate roots themselves
        api | lib | main) continue ;;
    esac

    #A rust identifier: letters, digits and underscores, not starting with a digit.
    #A directory such as "my-helpers" cannot be declared with `pub mod` at all.
    case "$module_name" in
        *[!A-Za-z0-9_]* | [0-9]*)
            echo "WARN: 'src/$module_name' is not a valid rust module name -> not declared in src/lib.rs" >&2
            continue
            ;;
    esac

    if [ -d "$entry" ] && [ ! -f "$entry/mod.rs" ]; then
        echo "WARN: 'src/$module_name/' carries no mod.rs -> not declared in src/lib.rs" >&2
        continue
    fi

    echo "Declaring hand-written module in the crate barrel: pub mod $module_name;"
    echo "pub mod $module_name;" >> "$LIB_ENTRY_FILE"
done

echo "Created crate barrel: $LIB_ENTRY_FILE"
