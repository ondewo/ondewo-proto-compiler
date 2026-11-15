#!/bin/sh
# Compiles tests/angular-compat/fixture-client with the angular compiler image and runs
# run-compat.sh on the npm/ package it produces: `make test_angular_compat`.
# Usage: compile-and-check.sh [<angular_version> ...]   (default: $ANGULAR_COMPAT_VERSIONS)
# Needs docker + network; build the image first (`make build_angular`).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${ANGULAR_COMPAT_IMAGE:-ondewo-angular-proto-compiler:latest}"
OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/angular-compat-fixture.XXXXXX")"

echo "---------------------------------------------------------------"
echo "Angular compat: compiling the fixture client with $IMAGE ..."
echo "---------------------------------------------------------------"
# The image runs as root (it writes under /image-data); the output dir is a throwaway temp dir.
docker run --rm -v "$SCRIPT_DIR/fixture-client":/input-volume:ro -v "$OUTPUT_DIR":/output-volume \
  "$IMAGE" protos ondewo

ANGULAR_COMPAT_EXTRA_CHECK="$SCRIPT_DIR/fixture-assertions.mjs" sh "$SCRIPT_DIR/run-compat.sh" "$OUTPUT_DIR/npm" "$@"
