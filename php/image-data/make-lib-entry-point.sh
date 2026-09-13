#!/bin/bash
set -e

# -------------- Create the library entry point: composer.json
#
# Usage: make-lib-entry-point.sh <temp_src_directory> [<default_lib_files_dir>]
#   <temp_src_directory>     root of the compilation (generated stubs live in <dir>/generated-src,
#                            and are published as src/ inside the staged package)
#   <default_lib_files_dir>  where the image keeps its default manifest
#                            (default: $IMAGE_DATA_DIRECTORY/default-lib-files)
#
# PHP has no barrel file and no compile step: the package's entry point IS its composer.json
# autoloader - without an `autoload.classmap` entry covering src/, every generated class is shipped
# but unreachable. So this step either installs the image default, or merges the client's own
# manifest with it:
#
#   * require   - the image default first, the CLIENT's constraint second, so a client that pins a
#                 version WINS. If that pin is outside what the image pre-warmed, the offline
#                 `composer update` in compile-stubs-2-lib.sh fails loudly; that deliberate, visible
#                 failure is preferable to silently rewriting the client's dependency.
#   * autoload  - "src/" is appended unconditionally and de-duplicated with `unique`, i.e. it is NOT
#                 overridable. src/ is compiler-owned (the orchestrator wipes it on every run), and a
#                 client manifest that simply forgot the entry would otherwise ship a library whose
#                 classmap contains nothing but vendor classes.

SRC_DIRECTORY=$1
DEFAULT_FILES_DIR=${2:-${IMAGE_DATA_DIRECTORY:-/image-data}/default-lib-files}

if [ -z "$SRC_DIRECTORY" ]; then
    echo "usage: make-lib-entry-point.sh <temp_src_directory> [<default_lib_files_dir>]" >&2
    exit 1
fi

if [ ! -d "$SRC_DIRECTORY" ]; then
    echo "ERROR: the compilation source directory '$SRC_DIRECTORY' does not exist - exiting" >&2
    exit 1
fi

DEFAULT_MANIFEST=$DEFAULT_FILES_DIR/composer.json
if [ ! -f "$DEFAULT_MANIFEST" ]; then
    echo "ERROR: the default library manifest '$DEFAULT_MANIFEST' is missing from the image - exiting" >&2
    exit 1
fi

MANIFEST=$SRC_DIRECTORY/composer.json

if [ ! -f "$MANIFEST" ]; then
    echo "No composer.json specified in source directory -> copying default file"
    cp "$DEFAULT_MANIFEST" "$MANIFEST" || { echo "ERROR: failed to copy '$DEFAULT_MANIFEST' to '$MANIFEST' - exiting" >&2; exit 1; }
    exit 0
fi

echo "composer.json found in source directory -> merging it with the image defaults"

MERGED_MANIFEST=$(mktemp "${TMPDIR:-/tmp}/composer-merged.XXXXXX")
trap 'rm -f "$MERGED_MANIFEST"' EXIT

#jq fails loudly on a malformed client manifest, which is exactly what should happen here.
jq -s '.[0] as $defaults | .[1] as $client | $client
       | .require = ($defaults.require + ($client.require // {}))
       | .autoload = (($client.autoload // {})
           | .classmap = (((.classmap // []) + ["src/"]) | unique))' \
    "$DEFAULT_MANIFEST" "$MANIFEST" > "$MERGED_MANIFEST" \
    || { echo "ERROR: failed to merge '$MANIFEST' with the image defaults - is it valid JSON? - exiting" >&2; exit 1; }

mv "$MERGED_MANIFEST" "$MANIFEST" || { echo "ERROR: failed to write the merged library manifest to '$MANIFEST' - exiting" >&2; exit 1; }

echo "Library manifest prepared: $MANIFEST"
