#!/bin/bash
set -e

# Append the public-api barrel for the generated proto stubs to a file.
#
# Usage: generate-public-api.sh <src_root> <output_file>
#   <src_root>     directory containing the generated "api" tree
#   <output_file>  file the "export ..." lines are appended to
#
# Every stub gets an `export *`. That alone is not enough: two protos in different
# packages may declare the same top-level symbol -- ondewo.nlu and ondewo.s2t both
# declare `ReasoningEffort` -- and a name reachable through two `export *` lines is
# ambiguous, so tsc fails the library build with TS2308. An explicit re-export takes
# precedence over star exports, so each duplicated symbol also gets one, bound to the
# first stub that declares it in sorted order (deterministic across runs).

SRC_ROOT=$1
OUTPUT_FILE=$2

if [ -z "$SRC_ROOT" ] || [ -z "$OUTPUT_FILE" ]; then
  echo "usage: generate-public-api.sh <src_root> <output_file>" >&2
  exit 1
fi

OUTPUT_FILE=$(cd "$(dirname "$OUTPUT_FILE")" && pwd)/$(basename "$OUTPUT_FILE")
cd "$SRC_ROOT" || exit 1

find api -iname "*.ts" | sort | while IFS= read -r stub; do
  echo "export * from './${stub%.*}';"
done >>"$OUTPUT_FILE"

# symbol<TAB>module for every top-level export, de-duplicated per stub (a stub may
# declare `export class X` and `export module X` for the same name).
SYMBOL_INDEX=$(mktemp)
trap 'rm -f "$SYMBOL_INDEX"' EXIT

find api -iname "*.ts" | sort | while IFS= read -r stub; do
  awk -v mod="./${stub%.*}" '
    /^export / {
      for (i = 2; i <= NF; i++) {
        token = $i
        if (token == "declare" || token == "abstract" || token == "default" ||
            token == "async" || token == "class" || token == "interface" ||
            token == "enum" || token == "const" || token == "let" ||
            token == "var" || token == "type" || token == "function" ||
            token == "module" || token == "namespace") continue
        gsub(/[^A-Za-z0-9_$].*$/, "", token)
        if (token != "") print token "\t" mod
        break
      }
    }
  ' "$stub" | sort -u
done >>"$SYMBOL_INDEX"

cut -f1 "$SYMBOL_INDEX" | sort | uniq -d | while IFS= read -r duplicate; do
  first_module=$(awk -F'\t' -v symbol="$duplicate" '$1 == symbol { print $2; exit }' "$SYMBOL_INDEX")
  echo "export { $duplicate } from '$first_module';" >>"$OUTPUT_FILE"
done
