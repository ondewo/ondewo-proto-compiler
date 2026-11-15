#!/bin/sh
# Client-SDK matrix cell for the angular target: regenerates one ondewo-*-client-angular repo IN
# PLACE with the prebuilt ondewo-angular-proto-compiler image, exactly like the client's own
# `npm run build` (src/package.json prebuild + generate + postbuild cleanup), then verifies it.
#
# Usage: angular.sh <client_dir>
#   <client_dir>  a checked-out client repo with its submodules initialised (recursively); it is
#                 mutated (throwaway copy or CI checkout).
# Env: ANGULAR_COMPILER_IMAGE   image to generate with (default ondewo-angular-proto-compiler:latest)
#      ANGULAR_COMPAT_VERSIONS  Angular majors run-compat.sh checks (default: this repo's Makefile)
# Needs on the host: docker, node 24 + npm, make, network (npm registry, docker hub node image).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_COMPAT="$SCRIPT_DIR/../angular-compat/run-compat.sh"
IMAGE="${ANGULAR_COMPILER_IMAGE:-ondewo-angular-proto-compiler:latest}"

fail() {
  echo "❌ Angular matrix: $*" >&2
  exit 1
}

[ -n "$1" ] && [ -d "$1" ] || fail "usage: $0 <client_dir> - '$1' is not a directory"
CLIENT_DIR="$(cd "$1" && pwd)"
NAME="$(basename "$CLIENT_DIR")"

for tool in docker node npm npx make; do
  command -v "$tool" >/dev/null 2>&1 || fail "required host tool '$tool' is not installed"
done
[ -f "$RUN_COMPAT" ] || fail "compat harness $RUN_COMPAT is missing"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "docker image $IMAGE is not built (run make build_angular)"

SRC_PACKAGE_JSON="$CLIENT_DIR/src/package.json"
[ -f "$SRC_PACKAGE_JSON" ] || fail "$NAME has no src/package.json - not an angular client"
[ -f "$CLIENT_DIR/package.json" ] && [ -f "$CLIENT_DIR/package-lock.json" ] ||
  fail "$NAME has no committed root package.json / package-lock.json"
[ -f "$CLIENT_DIR/jest.config.js" ] || fail "$NAME has no jest.config.js - no client test suite to run"

# The api dir is the first entrypoint argument of the client's own generate script.
API_DIR="$(sed -n 's|.*ondewo-angular-proto-compiler[:a-z0-9.]* \([A-Za-z0-9_.-]*\) ondewo".*|\1|p' "$SRC_PACKAGE_JSON")"
[ -n "$API_DIR" ] || fail "could not read the api dir from the generate script in $SRC_PACKAGE_JSON"
PROTOS_DIR="$CLIENT_DIR/src/$API_DIR/ondewo"
[ -d "$PROTOS_DIR" ] || fail "$PROTOS_DIR is missing - is the api submodule initialised?"
PROTO_COUNT="$(find "$PROTOS_DIR" -name '*.proto' | grep -c . || true)"
[ "$PROTO_COUNT" -gt 0 ] || fail "no .proto files under $PROTOS_DIR"

# survey-style prebuild: `cp <api>/googleapis/google <api>/ -R` before generate, removed after.
GOOGLE_COPY_API="$(sed -n 's|.*"prebuild": "cp \([A-Za-z0-9_.-]*\)/googleapis/google \1/ -R".*|\1|p' "$SRC_PACKAGE_JSON")"
if [ -n "$GOOGLE_COPY_API" ]; then
  [ -d "$CLIENT_DIR/src/$GOOGLE_COPY_API/googleapis/google" ] ||
    fail "prebuild needs src/$GOOGLE_COPY_API/googleapis/google - initialise the submodules recursively"
fi

echo "---------------------------------------------------------------"
echo "Angular matrix: $NAME - generating $PROTO_COUNT protos of $API_DIR with $IMAGE ..."
echo "---------------------------------------------------------------"

# ng-packagr writes a generated root manifest over the committed one, which carries the
# devDependencies and test scripts; the client's install_dependencies restores it with
# `git checkout --`. Same restore here, from a copy, so the script needs no git metadata.
KEEP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/angular-matrix.XXXXXX")"
cp "$CLIENT_DIR/package.json" "$CLIENT_DIR/package-lock.json" "$KEEP_DIR/"

# Drop every committed / previously generated compiler output first, so the checks below can only
# pass on files THIS run produced (a generation that silently wrote nothing would otherwise be
# judged on the stubs and bundles already in the checkout).
for out in api npm fesm2022 types public-api.ts; do
  rm -rf "${CLIENT_DIR:?}/$out"
done
if [ -n "$GOOGLE_COPY_API" ]; then
  cp -R "$CLIENT_DIR/src/$GOOGLE_COPY_API/googleapis/google" "$CLIENT_DIR/src/$GOOGLE_COPY_API/"
fi
rc=0
docker run --rm -v "$CLIENT_DIR/src":/input-volume -v "$CLIENT_DIR":/output-volume "$IMAGE" "$API_DIR" ondewo || rc=$?
# The image runs as root: hand the output back to the caller before anything else touches it.
docker run --rm -v "$CLIENT_DIR":/w alpine chown -R "$(id -u):$(id -g)" /w
if [ -n "$GOOGLE_COPY_API" ]; then
  rm -rf "${CLIENT_DIR:?}/src/${GOOGLE_COPY_API:?}/google"
fi
[ "$rc" -eq 0 ] || fail "$NAME: code generation failed (docker run rc=$rc)"
cp "$KEEP_DIR/package.json" "$KEEP_DIR/package-lock.json" "$CLIENT_DIR/"
rm -rf "$KEEP_DIR"

echo "---------------------------------------------------------------"
echo "✅ Angular matrix: $NAME - generated"
echo "---------------------------------------------------------------"

echo "---------------------------------------------------------------"
echo "Angular matrix: $NAME - checking the generated files ..."
echo "---------------------------------------------------------------"
GENERATED_COUNT="$(find "$CLIENT_DIR/api" -name '*.pb.ts' 2>/dev/null | grep -c . || true)"
[ "$GENERATED_COUNT" -gt 0 ] || fail "$NAME: no generated *.pb.ts under api/"
# One <name>.pb.ts per proto; protoc-gen-ng kebab-cases the file name (entity_type -> entity-type).
MISSING=""
for proto in $(cd "$CLIENT_DIR/src/$API_DIR" && find ondewo -name '*.proto'); do
  stub="$(dirname "$proto")/$(basename "$proto" .proto | tr '_' '-').pb.ts"
  [ -f "$CLIENT_DIR/api/$stub" ] || MISSING="$MISSING $stub"
done
[ -z "$MISSING" ] || fail "$NAME: no stub generated for:$MISSING"
FESM_COUNT="$(find "$CLIENT_DIR/npm/fesm2022" -name '*.mjs' 2>/dev/null | grep -c . || true)"
[ "$FESM_COUNT" -gt 0 ] || fail "$NAME: npm/fesm2022 holds no .mjs bundle"
# Every entry the generated (npm/) and the committed root manifest (what a consumer installing by
# commit reads) points at must exist.
node -e '
const fs = require("fs"), path = require("path");
let bad = [];
for (const dir of process.argv.slice(1)) {
  const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
  const entries = [pkg.module, pkg.typings, pkg.exports && pkg.exports["."] && pkg.exports["."].types,
    pkg.exports && pkg.exports["."] && pkg.exports["."].default];
  if (entries.some((e) => !e)) bad.push(`${dir}/package.json lacks module/typings/exports["."]`);
  for (const e of entries.filter(Boolean)) if (!fs.existsSync(path.join(dir, e))) bad.push(`${dir}/${e}`);
}
if (bad.length) { console.error("missing package entries:\n  " + bad.join("\n  ")); process.exit(1); }
' "$CLIENT_DIR/npm" "$CLIENT_DIR" || fail "$NAME: a package entry point does not exist"
echo "✅ Angular matrix: $NAME - $GENERATED_COUNT *.pb.ts for $PROTO_COUNT protos, $FESM_COUNT fesm2022 bundle(s)"

echo "---------------------------------------------------------------"
echo "Angular matrix: $NAME - ng build + runtime check of npm/ on every supported Angular ..."
echo "---------------------------------------------------------------"
sh "$RUN_COMPAT" "$CLIENT_DIR/npm" || fail "$NAME: the generated library failed the Angular compat check"

echo "---------------------------------------------------------------"
echo "Angular matrix: $NAME - client test suite (eslint, jest with coverage gate) and prettier ..."
echo "---------------------------------------------------------------"
(cd "$CLIENT_DIR" && npm ci --no-audit --no-fund --legacy-peer-deps --loglevel=error) ||
  fail "$NAME: npm ci of the committed lockfile failed"
# The same steps as the client's own .github/workflows: eslint where that CI runs it, then jest
# with the coverage gate of jest.config.js; plus the prettier check. All three run, then any
# failure fails the cell, so one red step does not hide the result of the others.
# That CI lints a checkout without the gitignored npm/ build output, so npm/ is set aside for it:
# the clients' eslint ignores cover the old npm/index.d.ts but not ng-packagr 22's npm/types/.
FAILED=""
if grep -qs 'make eslint' "$CLIENT_DIR"/.github/workflows/*.yml; then
  ASIDE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/angular-matrix-npm.XXXXXX")"
  mv "$CLIENT_DIR/npm" "$ASIDE_DIR/npm"
  (cd "$CLIENT_DIR" && make eslint) || FAILED="$FAILED eslint"
  mv "$ASIDE_DIR/npm" "$CLIENT_DIR/npm"
  rmdir "$ASIDE_DIR"
fi
(cd "$CLIENT_DIR" && npx jest --config jest.config.js --coverage --ci) || FAILED="$FAILED jest"
(cd "$CLIENT_DIR" && make prettier) || FAILED="$FAILED prettier"
[ -z "$FAILED" ] || fail "$NAME: client checks failed on the regenerated tree:$FAILED"

echo "---------------------------------------------------------------"
echo "✅ Angular matrix: $NAME passed"
echo "---------------------------------------------------------------"
