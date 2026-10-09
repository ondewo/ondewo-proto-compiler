#!/bin/bash
set -e

# -------------- Create pulbic-api.js from the commonjs output of the proto compilation step
# to pass a single file to webpack as an entry point

#Root directory of the compilation ( -> public api file in this directory + proto commonjs stubs are in this/api )
TEMP_SRC_DIRECTORY=$1

FILE_EXTENSION=$2
if [ -z "$2" ]; then
    FILE_EXTENSION=".d.ts"
fi

#Location of the directory where the target api file will be put
#OUT_DIRECTORY=$2
DEFAULT_FILES_DIR=default-lib-files

#Can also be specified in provided directory -> no auto generation
PUBLIC_API_FILE=$TEMP_SRC_DIRECTORY/public-api$FILE_EXTENSION

if [ ! -f "$PUBLIC_API_FILE" ]; then
    echo "No public-api$FILE_EXTENSION specified in source directory -> copying default file"
    cp "$DEFAULT_FILES_DIR/public-api$FILE_EXTENSION" "$PUBLIC_API_FILE"

    # Trying to auto generate public-api file
    cd "$TEMP_SRC_DIRECTORY" || exit 1

    if [ "$FILE_EXTENSION" = ".js" ]; then
        # The .js barrel is the package's `main` and must be COMMONJS: the package has no
        # "type": "module" and every stub is commonjs (`--js_out=import_style=commonjs`). An
        # `export * from` barrel made Node load the file as an ES module (syntax detection,
        # Node >= 20.19 / 22 / 24), whose resolver demands file extensions, so
        # `require('<package>')` failed with ERR_MODULE_NOT_FOUND (older Node: SyntaxError).
        # Each stub is re-exported through getters; the FIRST stub (sorted order) that exports
        # a name keeps it, the same binding the .d.ts barrel's explicit re-exports below make.
        # append-auth-exports.sh recognises the `function reexport(` helper and appends the
        # hand-written auth modules in the same form.
        cat >> "$PUBLIC_API_FILE" <<'EOF'
'use strict';
function reexport(m) {
  Object.keys(m).forEach(function (k) {
    if (k !== 'default' && !Object.prototype.hasOwnProperty.call(exports, k)) {
      Object.defineProperty(exports, k, { enumerable: true, get: function () { return m[k]; } });
    }
  });
}
EOF
        find api -iname "*.js" | sort | while IFS= read -r stub; do
            printf "reexport(require('./%s'));\n" "${stub%.js}"
        done >> "$PUBLIC_API_FILE"
    else
        #ES6 Style exports
        export PREFIX="export * from '"
        export POSTFIX="';"

        #find api -iname "*.ts" -printf "$PREFIX%p$POSTFIX\n" >> $PUBLIC_API_FILE
        find api -iname "*$FILE_EXTENSION" -exec bash -c 'printf "$PREFIX./%s$POSTFIX\n" "${@%.*}"' _ {} + >> "$PUBLIC_API_FILE"
    fi

    # A star export alone is not enough. Two protos in different packages may legitimately
    # declare the same top-level symbol -- ondewo.nlu and ondewo.s2t both declare
    # `ReasoningEffort` -- and a name reachable through two `export *` lines is ambiguous:
    # tsc fails the consumer's build with TS2308 on the .d.ts barrel, and ESM silently drops
    # the name instead of exporting it. An explicit re-export takes precedence over star
    # exports, so each duplicated symbol also gets one, bound to the first stub that declares
    # it in sorted order (deterministic across runs). The generated .js stubs are closure /
    # commonjs and carry no `export ` lines, so this is inert for the .js barrel and only the
    # .d.ts barrel is actually disambiguated.
    # symbol<TAB>module for every top-level export, de-duplicated per stub (a stub declares
    # both `export class X` and `export namespace X` for the same message).
    SYMBOL_INDEX=$(mktemp "${TMPDIR:-/tmp}/public-api-symbols.XXXXXX")
    trap 'rm -f "$SYMBOL_INDEX"' EXIT

    find api -iname "*$FILE_EXTENSION" | sort | while IFS= read -r stub; do
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
        echo "export { $duplicate } from '$first_module';" >> "$PUBLIC_API_FILE"
    done
fi
