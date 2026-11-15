#!/bin/sh
# Proves that an angular client library built by ondewo-angular-proto-compiler works on every
# supported Angular major. For each version it installs the PACKED library into a throwaway
# consumer app under strict peer resolution, then
#   1. `ng build` (AOT, production)  -> that major's linker accepts the partial declarations and
#      its TypeScript accepts the shipped .d.ts (skipLibCheck: false),
#   2. `node runtime-check.mjs`      -> on that major's runtime every generated *Client is
#      injectable, every RPC round-trips through GrpcHandler, every message (de)serialises.
#
# Usage: run-compat.sh <npm_package_dir> [<angular_version> ...]
#   <npm_package_dir>  the npm/ folder the compiler writes to the output volume
#   <angular_version>  npm version spec of @angular/core, default: $ANGULAR_COMPAT_VERSIONS, else the
#                      ANGULAR_COMPAT_VERSIONS of this repo's Makefile (so a client running this script
#                      from its ondewo-proto-compiler submodule tests exactly the compiler's matrix)
# ANGULAR_COMPAT_EXTRA_CHECK=<file.mjs> adds library-specific assertions, run as a third step.
# Needs docker and network (npm registry); it is an integration test, not part of `make test`.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$1" ] || [ ! -f "$1/package.json" ]; then
  echo "ERROR: usage: $0 <npm_package_dir> [<angular_version> ...] - '$1' holds no package.json" >&2
  exit 2
fi
PACKAGE_DIR="$(cd "$1" && pwd)"
shift
VERSIONS="$*"
if [ -z "$VERSIONS" ]; then
  VERSIONS="${ANGULAR_COMPAT_VERSIONS:-$(sed -n 's/^ANGULAR_COMPAT_VERSIONS=//p' "$SCRIPT_DIR/../../Makefile")}"
fi
if [ -z "$VERSIONS" ]; then
  echo "ERROR: no Angular versions given and no ANGULAR_COMPAT_VERSIONS in $SCRIPT_DIR/../../Makefile" >&2
  exit 2
fi
NODE_IMAGE="${ANGULAR_COMPAT_NODE_IMAGE:-node:24-slim}"
WORK_DIR="${ANGULAR_COMPAT_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/angular-compat.XXXXXX")}"
mkdir -p "$WORK_DIR/package" "$WORK_DIR/.home"

echo "---------------------------------------------------------------"
echo "Angular compat: packing $PACKAGE_DIR"
echo "---------------------------------------------------------------"
cp -R "$PACKAGE_DIR"/. "$WORK_DIR/package/"
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/work/.home -v "$WORK_DIR":/work -w /work/package \
  "$NODE_IMAGE" npm pack --silent --pack-destination /work >/dev/null
TARBALL="$(cd "$WORK_DIR" && ls ./*.tgz)"

FAILED=""
for version in $VERSIONS; do
  echo "---------------------------------------------------------------"
  echo "Angular compat: checking the library against @angular/core@$version ..."
  echo "---------------------------------------------------------------"
  rm -rf "${WORK_DIR:?}/app-$version"
  cp -R "$SCRIPT_DIR/consumer" "$WORK_DIR/app-$version"
  if [ -n "${ANGULAR_COMPAT_EXTRA_CHECK:-}" ]; then
    cp "$ANGULAR_COMPAT_EXTRA_CHECK" "$WORK_DIR/app-$version/extra-check.mjs"
  fi
  if docker run --rm --user "$(id -u):$(id -g)" -e HOME=/work/.home -v "$WORK_DIR":/work \
    -w "/work/app-$version" "$NODE_IMAGE" sh ./check.sh "$version" "/work/${TARBALL#./}"; then
    echo "✅ Angular compat: @angular/core@$version passed"
  else
    echo "❌ Angular compat: @angular/core@$version FAILED" >&2
    FAILED="$FAILED $version"
  fi
done

echo "---------------------------------------------------------------"
if [ -n "$FAILED" ]; then
  echo "❌ Angular compat: failed for:$FAILED (work dir kept: $WORK_DIR)" >&2
  echo "---------------------------------------------------------------"
  exit 1
fi
echo "✅ Angular compat: library works on Angular $VERSIONS"
echo "---------------------------------------------------------------"
