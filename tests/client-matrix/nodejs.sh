#!/bin/sh
# Client-SDK matrix cell for the nodejs target.
#
#   sh tests/client-matrix/nodejs.sh <client_dir>
#
# <client_dir> is a checked-out ondewo-<product>-client-nodejs repo with its submodules initialised. It
# is mutated in place: api/ and public-api.* are wiped and regenerated with the prebuilt
# ondewo-nodejs-proto-compiler:latest image exactly the way the client's own `make build` does it
# (minus the submodule re-checkout, the compiler rebuild and the sudo chown), then the client's own
# test suite and a package smoke check run against the fresh output.

set -e

IMAGE="ondewo-nodejs-proto-compiler:latest"

fail() {
    echo "ERROR: nodejs matrix: $*" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "usage: sh $0 <client_dir>"
[ -d "$1" ] || fail "client dir '$1' does not exist"
CLIENT_DIR="$(cd "$1" && pwd)"
SRC_DIR="$CLIENT_DIR/src"
API_DIR="$CLIENT_DIR/api"
CLIENT_NAME="$(basename "$CLIENT_DIR")"

for tool in docker node npm make git; do
    command -v "$tool" >/dev/null 2>&1 || fail "required host tool '$tool' is not on PATH"
done
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "docker image '$IMAGE' is not built"
[ -f "$SRC_DIR/package.json" ] || fail "$SRC_DIR/package.json is missing (not a nodejs client?)"
[ -f "$CLIENT_DIR/package.json" ] || fail "$CLIENT_DIR/package.json is missing"
[ -f "$CLIENT_DIR/Makefile" ] || fail "$CLIENT_DIR/Makefile is missing"

# -------------- Derive the generate arguments from the client's own build script
# Every nodejs client spells it as
#   docker run -v ${PWD}:/input-volume -v ${PWD}/..:/output-volume ondewo-nodejs-proto-compiler <protos_dir> <subdir>
# run from src/ (the newer Makefiles inline the same call with --rm). Anything else is a contract
# change this script must not guess at.
BUILD_SCRIPT="$(node -e 'const s=(require(process.argv[1]).scripts||{}).build;if(!s)process.exit(1);process.stdout.write(s)' "$SRC_DIR/package.json")" \
    || fail "$SRC_DIR/package.json has no \"build\" script"
# shellcheck disable=SC2016  # ${PWD} is the literal text of the client's npm script
EXPECTED_PREFIX='docker run -v ${PWD}:/input-volume -v ${PWD}/..:/output-volume ondewo-nodejs-proto-compiler '
case "$BUILD_SCRIPT" in
    "$EXPECTED_PREFIX"*) ;;
    *) fail "unexpected src/package.json build script (volume/image contract changed): $BUILD_SCRIPT" ;;
esac
COMPILER_ARGS="${BUILD_SCRIPT#"$EXPECTED_PREFIX"}"
# shellcheck disable=SC2086  # intentional word splitting of the compiler argument list
set -- $COMPILER_ARGS
[ "$#" -eq 2 ] || fail "expected 2 compiler args <protos_dir> <subdir>, got $#: $COMPILER_ARGS"
API_SUBMODULE="$SRC_DIR/$1"
TARGET_SUBDIR="$2"
SELECTED_DIR="$API_SUBMODULE/$TARGET_SUBDIR"
[ -d "$SELECTED_DIR" ] || fail "protos dir '$SELECTED_DIR' does not exist (api submodule not initialised?)"
PROTO_COUNT="$(find "$SELECTED_DIR" -name '*.proto' | grep -c . || true)"
[ "$PROTO_COUNT" -gt 0 ] || fail "no .proto files under '$SELECTED_DIR' (api submodule empty?)"
API_STATUS_BEFORE="$(git -C "$API_SUBMODULE" status --porcelain)" \
    || fail "'$API_SUBMODULE' is not a git checkout (api submodule not initialised?)"

# Protos the client's Makefile leaves out of its codegen (CODEGEN_EXCLUDED_PROTOS, paths relative to the
# api submodule; vtsi drops the vendored ondewo/nlu/logs.proto, whose `service Logs` would otherwise take
# its own LogsClient's name). Moved aside for the generate run exactly as the client's `make build` does.
EXCLUDED_PROTOS="$(sed -n 's|^CODEGEN_EXCLUDED_PROTOS[[:space:]]*[:?]\{0,1\}=[[:space:]]*||p' "$CLIENT_DIR/Makefile" 2>/dev/null | head -n 1)"
EXCLUDED_KEEP="$(mktemp -d "${TMPDIR:-/tmp}/client-matrix-excluded.XXXXXX")"
for excluded in $EXCLUDED_PROTOS; do
    [ -f "$API_SUBMODULE/$excluded" ] || fail "CODEGEN_EXCLUDED_PROTOS names '$excluded', which is not under $API_SUBMODULE"
done

# The make `build` recipe is the authority on which post-codegen steps a client runs.
BUILD_RECIPE="$(sed -n '/^build:/,/^[A-Za-z_][A-Za-z_]*:/p' "$CLIENT_DIR/Makefile")"
[ -n "$BUILD_RECIPE" ] || fail "$CLIENT_DIR/Makefile has no 'build' target"

# Some api repos (survey) carry google/ only inside a googleapis/ checkout; the client's
# check_out_correct_submodule_versions copies it next to ondewo/ before the codegen and its build
# removes it afterwards.
COPIED_GOOGLE=""
if [ ! -d "$API_SUBMODULE/google" ] && [ -d "$API_SUBMODULE/googleapis/google" ]; then
    printf '%s\n' "$BUILD_RECIPE" "$(sed -n '/^check_out_correct_submodule_versions:/,/^[A-Za-z_][A-Za-z_]*:/p' "$CLIENT_DIR/Makefile")" \
        | grep -q 'googleapis/google' \
        || fail "$API_SUBMODULE has googleapis/google but the client Makefile never copies it - unknown layout"
    cp -R "$API_SUBMODULE/googleapis/google" "$API_SUBMODULE/google"
    COPIED_GOOGLE="yes"
fi

echo "---------------------------------------------------------------"
echo "nodejs matrix: $CLIENT_NAME - regenerating api/ ($PROTO_COUNT protos, args: $COMPILER_ARGS${COPIED_GOOGLE:+, google/ from googleapis/})"
echo "---------------------------------------------------------------"

# Wipe the committed output first: a regeneration that silently produced nothing must not pass on
# the files the repo already carries.
rm -rf "$API_DIR" "$CLIENT_DIR/public-api.js" "$CLIENT_DIR/public-api.d.ts"

for excluded in $EXCLUDED_PROTOS; do
    mkdir -p "$EXCLUDED_KEEP/$(dirname "$excluded")"
    mv "$API_SUBMODULE/$excluded" "$EXCLUDED_KEEP/$excluded"
done
GEN_STATUS=0
# shellcheck disable=SC2086  # intentional word splitting of the compiler argument list
docker run --rm -v "$SRC_DIR":/input-volume -v "$CLIENT_DIR":/output-volume "$IMAGE" $COMPILER_ARGS || GEN_STATUS=$?
# The image runs as root: hand the output back to the invoking user before checking anything.
docker run --rm -v "$CLIENT_DIR":/w alpine chown -R "$(id -u):$(id -g)" /w
for excluded in $EXCLUDED_PROTOS; do
    mv "$EXCLUDED_KEEP/$excluded" "$API_SUBMODULE/$excluded"
done
rm -rf "$EXCLUDED_KEEP"
[ "$GEN_STATUS" -eq 0 ] || fail "$IMAGE exited with status $GEN_STATUS"

[ -z "$COPIED_GOOGLE" ] || rm -rf "$API_SUBMODULE/google"
[ "$(git -C "$API_SUBMODULE" status --porcelain)" = "$API_STATUS_BEFORE" ] \
    || fail "the codegen modified the mounted api submodule $API_SUBMODULE: $(git -C "$API_SUBMODULE" status --porcelain)"

[ -d "$API_DIR" ] || fail "no api/ directory generated in $CLIENT_DIR"
for f in public-api.js public-api.d.ts; do
    [ -s "$CLIENT_DIR/$f" ] || fail "generated $f is missing or empty"
done
GENERATED_COUNT="$(find "$API_DIR" -type f | grep -c . || true)"
[ "$GENERATED_COUNT" -gt 0 ] || fail "no files generated in $API_DIR"
# Every selected proto must come out as message + service stubs at its own relative path.
MISSING_STUBS="$(cd "$API_SUBMODULE" && find "$TARGET_SUBDIR" -name '*.proto' | while IFS= read -r proto; do
    case " $EXCLUDED_PROTOS " in *" $proto "*) continue ;; esac
    stem="${proto%.proto}"
    for suffix in _pb.js _pb.d.ts _grpc_pb.js; do
        [ -f "$API_DIR/$stem$suffix" ] || echo "api/$stem$suffix"
    done
done)"
[ -z "$MISSING_STUBS" ] || fail "stubs missing for selected protos:
$MISSING_STUBS"

echo "---------------------------------------------------------------"
echo "✅ nodejs matrix: $CLIENT_NAME - generated $GENERATED_COUNT files in api/"
echo "---------------------------------------------------------------"

# -------------- The rest of the client's `make build`, then its CI install
echo "---------------------------------------------------------------"
echo "nodejs matrix: $CLIENT_NAME - replaying the client's post-codegen build steps ..."
echo "---------------------------------------------------------------"

cd "$CLIENT_DIR"
cp src/README.md .
cp src/RELEASE.md .
# Replay the make targets the client's `build` recipe calls after the codegen, in the client's own
# order. The codegen overwrites package.json and package-lock.json with the runtime-only versions, and
# restore_ci_test_setup + install_dependencies are how the client brings them back in sync. Only these
# local, side-effect-free targets are known; anything else in the recipe is a contract change.
POST_TARGETS="$(printf '%s\n' "$BUILD_RECIPE" | sed -n -E 's/^[[:space:]]*(make|\$\(MAKE\))[[:space:]]+([A-Za-z_]+)[[:space:]]*$/\2/p')"
[ -n "$POST_TARGETS" ] || fail "no post-codegen make targets found in the 'build' recipe of $CLIENT_DIR/Makefile"
for target in $POST_TARGETS; do
    case "$target" in
        restore_ci_test_setup | create_npm_package | remove_npm_script | install_dependencies | compile_auth) ;;
        *) fail "unknown post-codegen target '$target' in the 'build' recipe of $CLIENT_DIR/Makefile" ;;
    esac
    make "$target" || fail "make $target failed in $CLIENT_NAME"
done
# Then install exactly the way the client's CI does: npm ci fails if the lock is out of sync.
[ -f package-lock.json ] || fail "$CLIENT_DIR/package-lock.json is missing"
npm ci --no-audit --no-fund || fail "npm ci failed in $CLIENT_DIR (package-lock.json out of sync after the build)"
make check_build || fail "make check_build (client's own stub completeness check) failed in $CLIENT_NAME"

echo "---------------------------------------------------------------"
echo "✅ nodejs matrix: $CLIENT_NAME - post-codegen build steps done"
echo "---------------------------------------------------------------"

# -------------- Smoke: the package entry loads in plain node and exposes working service clients
echo "---------------------------------------------------------------"
echo "nodejs matrix: $CLIENT_NAME - package smoke check ..."
echo "---------------------------------------------------------------"

node -e '
const fs = require("fs"), path = require("path");
const [clientDir, protosDir] = process.argv.slice(1);
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
const grpc = require(require.resolve("@grpc/grpc-js", { paths: [clientDir] }));
for (const entry of [clientDir, path.join(clientDir, "npm")]) {
  const pkg = require(path.join(entry, "package.json"));
  const mod = require(entry);
  const keys = Object.keys(mod);
  const missing = services.filter((s) => typeof mod[s + "Client"] !== "function");
  if (missing.length) { console.error(entry + ": no <Service>Client export for: " + missing.join(", ")); process.exit(1); }
  for (const s of services) new mod[s + "Client"]("localhost:1", grpc.credentials.createInsecure()).close();
  const msgs = keys.filter((k) => typeof mod[k] === "function" && typeof mod[k].prototype?.serializeBinary === "function");
  if (!msgs.length) { console.error(entry + ": no protobuf message classes exported"); process.exit(1); }
  const bytes = new mod[msgs[0]]().serializeBinary();
  mod[msgs[0]].deserializeBinary(bytes);
  console.log(entry + " (" + pkg.name + "@" + pkg.version + "): OK - " + keys.length + " exports, " +
    services.length + " service clients constructed, " + msgs.length + " message classes");
}
' "$CLIENT_DIR" "$SELECTED_DIR" || fail "package smoke check failed"

echo "---------------------------------------------------------------"
echo "✅ nodejs matrix: $CLIENT_NAME - package smoke check passed"
echo "---------------------------------------------------------------"

# -------------- The client's own test suite, against the regenerated package
echo "---------------------------------------------------------------"
echo "nodejs matrix: $CLIENT_NAME - running the client's test suite ..."
echo "---------------------------------------------------------------"

node -e 'const s=(require("./package.json").scripts||{}).test;if(!s||/no test specified/.test(s))process.exit(1)' \
    || fail "$CLIENT_DIR/package.json has no real \"test\" script"
npm test || fail "npm test failed in $CLIENT_NAME"

# Extra gates the clients' CI runs beside `npm test` - run each one the client defines.
EXTRA_SCRIPTS="$(node -e '
const s = require("./package.json").scripts || {};
for (const n of ["test:drift", "typecheck:examples", "test:examples", "test:protos"]) if (s[n]) console.log(n);
')"
for script in $EXTRA_SCRIPTS; do
    npm run "$script" || fail "npm run $script failed in $CLIENT_NAME"
done

echo "---------------------------------------------------------------"
echo "✅ nodejs matrix: $CLIENT_NAME - generation, smoke check and client tests passed"
echo "---------------------------------------------------------------"
