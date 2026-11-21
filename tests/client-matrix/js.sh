#!/bin/sh
# Client-SDK matrix cell for the js target.
#
#   sh tests/client-matrix/js.sh <client_dir>
#
# <client_dir> is a checked-out ondewo-<product>-client-js repo with its submodules initialised. It is
# mutated in place: api/ is wiped and regenerated with the prebuilt ondewo-js-proto-compiler:latest
# image exactly the way the client's own `src/package.json` "build" script does it, then the client's
# own test suite and a bundle smoke check run against the fresh output.

set -e

IMAGE="ondewo-js-proto-compiler:latest"

fail() {
    echo "ERROR: js matrix: $*" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "usage: sh $0 <client_dir>"
[ -d "$1" ] || fail "client dir '$1' does not exist"
CLIENT_DIR="$(cd "$1" && pwd)"
SRC_DIR="$CLIENT_DIR/src"
API_DIR="$CLIENT_DIR/api"
CLIENT_NAME="$(basename "$CLIENT_DIR")"

for tool in docker node npm make; do
    command -v "$tool" >/dev/null 2>&1 || fail "required host tool '$tool' is not on PATH"
done
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "docker image '$IMAGE' is not built"
[ -f "$SRC_DIR/package.json" ] || fail "$SRC_DIR/package.json is missing (not a js client?)"
[ -f "$CLIENT_DIR/package.json" ] || fail "$CLIENT_DIR/package.json is missing"

# -------------- Derive the generate arguments from the client's own build script
# Every js client spells it as
#   docker run -v ${PWD}:/input-volume -v ${PWD}/../api:/output-volume ondewo-js-proto-compiler <lib> <protos_dir> <subdir>
# run from src/. Anything else is a contract change this script must not guess at.
BUILD_SCRIPT="$(node -e 'const s=(require(process.argv[1]).scripts||{}).build;if(!s)process.exit(1);process.stdout.write(s)' "$SRC_DIR/package.json")" \
    || fail "$SRC_DIR/package.json has no \"build\" script"
EXPECTED_PREFIX='docker run -v ${PWD}:/input-volume -v ${PWD}/../api:/output-volume ondewo-js-proto-compiler '
case "$BUILD_SCRIPT" in
    "$EXPECTED_PREFIX"*) ;;
    *) fail "unexpected src/package.json build script (volume/image contract changed): $BUILD_SCRIPT" ;;
esac
COMPILER_ARGS="${BUILD_SCRIPT#"$EXPECTED_PREFIX"}"
# shellcheck disable=SC2086  # intentional word splitting of the compiler argument list
set -- $COMPILER_ARGS
[ "$#" -eq 3 ] || fail "expected 3 compiler args <lib> <protos_dir> <subdir>, got $#: $COMPILER_ARGS"
LIB_NAME="$(echo "$1" | sed -e 's/-/_/g')"
PROTOS_DIR="$SRC_DIR/$2"
SELECTED_DIR="$PROTOS_DIR/$3"
[ -d "$SELECTED_DIR" ] || fail "protos dir '$SELECTED_DIR' does not exist (api submodule not initialised?)"
PROTO_COUNT="$(find "$SELECTED_DIR" -name '*.proto' | grep -c . || true)"
[ "$PROTO_COUNT" -gt 0 ] || fail "no .proto files under '$SELECTED_DIR' (api submodule empty?)"

# Protos the client's Makefile leaves out of its codegen (CODEGEN_EXCLUDED_PROTOS, paths relative to the
# api submodule; vtsi drops the vendored ondewo/nlu/logs.proto, whose `service Logs` would otherwise take
# its own LogsClient's name). Moved aside for the generate run exactly as the client's `make build` does.
EXCLUDED_PROTOS="$(sed -n 's|^CODEGEN_EXCLUDED_PROTOS[[:space:]]*[:?]\{0,1\}=[[:space:]]*||p' "$CLIENT_DIR/Makefile" 2>/dev/null | head -n 1)"
EXCLUDED_KEEP="$(mktemp -d "${TMPDIR:-/tmp}/client-matrix-excluded.XXXXXX")"
for excluded in $EXCLUDED_PROTOS; do
    [ -f "$PROTOS_DIR/$excluded" ] || fail "CODEGEN_EXCLUDED_PROTOS names '$excluded', which is not under $PROTOS_DIR"
done

# An api repo that vendors googleapis as a submodule (survey) has no top-level google/; the client's
# own `check_out_correct_submodule_versions` copies googleapis/google into place before generating.
if [ ! -d "$PROTOS_DIR/google" ] && [ -d "$PROTOS_DIR/googleapis/google" ]; then
    echo "js matrix: $CLIENT_NAME - copying googleapis/google to $2/google (as the client's Makefile does)"
    cp -R "$PROTOS_DIR/googleapis/google" "$PROTOS_DIR/google"
fi

echo "---------------------------------------------------------------"
echo "js matrix: $CLIENT_NAME - regenerating api/ ($PROTO_COUNT protos, lib '$LIB_NAME', args: $COMPILER_ARGS)"
echo "---------------------------------------------------------------"

# Wipe the committed bundle first: a regeneration that silently produced nothing must not pass on
# the files the repo already carries.
mkdir -p "$API_DIR"
rm -f "$API_DIR/$LIB_NAME.js" "$API_DIR/$LIB_NAME.min.js" "$API_DIR/$LIB_NAME.min.js.map"

for excluded in $EXCLUDED_PROTOS; do
    mkdir -p "$EXCLUDED_KEEP/$(dirname "$excluded")"
    mv "$PROTOS_DIR/$excluded" "$EXCLUDED_KEEP/$excluded"
done
GEN_STATUS=0
# shellcheck disable=SC2086  # intentional word splitting of the compiler argument list
docker run --rm -v "$SRC_DIR":/input-volume -v "$API_DIR":/output-volume "$IMAGE" $COMPILER_ARGS || GEN_STATUS=$?
# The image runs as root: hand the output back to the invoking user before checking anything.
docker run --rm -v "$API_DIR":/w alpine chown -R "$(id -u):$(id -g)" /w
for excluded in $EXCLUDED_PROTOS; do
    mv "$EXCLUDED_KEEP/$excluded" "$PROTOS_DIR/$excluded"
done
rm -rf "$EXCLUDED_KEEP"
[ "$GEN_STATUS" -eq 0 ] || fail "$IMAGE exited with status $GEN_STATUS"

GENERATED_COUNT="$(find "$API_DIR" -type f | grep -c . || true)"
[ "$GENERATED_COUNT" -gt 0 ] || fail "no files generated in $API_DIR"
for f in "$LIB_NAME.js" "$LIB_NAME.min.js" "$LIB_NAME.min.js.map"; do
    [ -s "$API_DIR/$f" ] || fail "generated bundle file api/$f is missing or empty"
done
# The client's own completeness check: every proto and google import has code in the bundle.
make -C "$CLIENT_DIR" check_build || fail "make check_build failed in $CLIENT_NAME"

echo "---------------------------------------------------------------"
echo "✅ js matrix: $CLIENT_NAME - generated $GENERATED_COUNT files in api/"
echo "---------------------------------------------------------------"

# -------------- Smoke: both bundles load self-contained and expose a client for every service
echo "---------------------------------------------------------------"
echo "js matrix: $CLIENT_NAME - bundle smoke check ..."
echo "---------------------------------------------------------------"

node -e '
const fs = require("fs"), path = require("path"), vm = require("vm");
const [apiDir, lib, protosDir] = process.argv.slice(1);
const services = [];
(function walk(d) {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith(".proto")) {
      const src = fs.readFileSync(p, "utf8").replace(/\/\*[^]*?\*\//g, "").replace(/\/\/.*$/gm, "");
      for (const m of src.matchAll(/^[ \t]*service[ \t]+(\w+)[ \t]*\{/gm)) services.push(m[1]);
    }
  }
})(protosDir);
if (!services.length) { console.error("no service declarations found under " + protosDir); process.exit(1); }
for (const file of [lib + ".js", lib + ".min.js"]) {
  const ctx = { window: {}, global: {}, self: {} };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(apiDir, file), "utf8"), ctx, { filename: file });
  const ns = ctx[lib];
  if (!ns || typeof ns !== "object") { console.error(file + ": bundle did not define the global " + lib); process.exit(1); }
  const keys = Object.keys(ns);
  const missing = services.filter((s) => typeof ns[s + "Client"] !== "function");
  if (missing.length) { console.error(file + ": no <Service>Client export for: " + missing.join(", ")); process.exit(1); }
  for (const s of services) new ns[s + "Client"]("https://example.invalid:443");
  console.log(file + ": OK - " + keys.length + " exports, " + services.length + " service clients constructed");
}
' "$API_DIR" "$LIB_NAME" "$SELECTED_DIR" || fail "bundle smoke check failed"

echo "---------------------------------------------------------------"
echo "✅ js matrix: $CLIENT_NAME - bundle smoke check passed"
echo "---------------------------------------------------------------"

# -------------- The client's own test suite, against the regenerated bundle
echo "---------------------------------------------------------------"
echo "js matrix: $CLIENT_NAME - running the client's test suite ..."
echo "---------------------------------------------------------------"

cd "$CLIENT_DIR"
if [ -f package-lock.json ]; then
    npm ci --no-audit --no-fund || fail "npm ci failed in $CLIENT_DIR"
else
    npm install --no-audit --no-fund || fail "npm install failed in $CLIENT_DIR"
fi
node -e 'const s=(require("./package.json").scripts||{}).test;if(!s||/no test specified/.test(s))process.exit(1)' \
    || fail "$CLIENT_DIR/package.json has no real \"test\" script"
npm test || fail "npm test failed in $CLIENT_NAME"

# Extra gates some clients' CI runs beside `npm test` (typecheck, package.json drift, examples) -
# run each one the client defines unless `npm test` already chains it.
EXTRA_SCRIPTS="$(node -e '
const s = require("./package.json").scripts || {};
const t = s.test || "";
for (const n of ["typecheck", "test:drift", "test:examples"])
  if (s[n] && !t.includes("npm run " + n)) console.log(n);
')"
for script in $EXTRA_SCRIPTS; do
    npm run "$script" || fail "npm run $script failed in $CLIENT_NAME"
done

echo "---------------------------------------------------------------"
echo "✅ js matrix: $CLIENT_NAME - generation, smoke check and client tests passed"
echo "---------------------------------------------------------------"
