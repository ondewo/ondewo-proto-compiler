#!/bin/bash
set -e

# Append the client's hand-written auth barrel to the generated public-api barrels.
#
# Usage: append-auth-exports.sh <output_root>
#   <output_root>  directory holding the generated public-api.* and the client's auth/
#
# This target keeps hand-written sources at the OUTPUT volume root, beside the generated
# barrels, rather than inside the mounted input directory the way the angular target does --
# so the export is appended here rather than by make-lib-entry-point.sh, which only ever sees
# the input volume. Without it the client ships auth/ but nothing re-exports it: importing a
# symbol from the package root does not resolve and consumers can only deep-import the module.
#
# Every non-spec module directly under auth/ is exported once, keyed by basename so the .ts /
# .js / .d.ts spellings of one module collapse into a single export. Re-running is safe: an
# export already present is not appended twice.

OUTPUT_ROOT=$1

if [ -z "$OUTPUT_ROOT" ]; then
  echo "usage: append-auth-exports.sh <output_root>" >&2
  exit 1
fi

AUTH_DIR=$OUTPUT_ROOT/auth
if [ ! -d "$AUTH_DIR" ]; then
  echo "No auth/ directory in $OUTPUT_ROOT -> nothing to re-export"
  exit 0
fi

find "$AUTH_DIR" -maxdepth 1 -type f \( -name "*.ts" -o -name "*.js" \) \
  ! -name "*.spec.*" ! -name "*.test.*" -exec basename {} \; |
  sed -e 's/\.d\.ts$//' -e 's/\.ts$//' -e 's/\.js$//' |
  sort -u |
  while IFS= read -r module; do
    [ -n "$module" ] || continue
    # A quote, backslash or space in the basename would emit a syntactically broken export
    # line and take the whole barrel down with it. Skip loudly instead.
    case $module in
      *[\'\"\\\ ]*)
        echo "append-auth-exports: skipping auth module with an unsafe name: $module" >&2
        continue
        ;;
    esac
    for barrel in "$OUTPUT_ROOT/public-api.d.ts" "$OUTPUT_ROOT/public-api.js"; do
      [ -f "$barrel" ] || continue
      if ! grep -Fq "'./auth/$module'" "$barrel"; then
        echo "export * from './auth/$module';" >>"$barrel"
      fi
    done
  done
