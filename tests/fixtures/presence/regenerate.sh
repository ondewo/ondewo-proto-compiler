#!/bin/sh
set -e

# Regenerate the presence fixture artifacts from presence.proto.
#
#   sh tests/fixtures/presence/regenerate.sh
#
# Both artifacts must come from the SAME toolchain the pipeline uses, so this runs inside the
# angular compiler image (build it first with `make build_angular`). It reproduces the two
# halves of compile-proto-2-stubs.sh in order:
#
#   1. the descriptor set is taken from the proto AS WRITTEN, while the `optional` keyword -
#      and with it every proto3_optional marker - is still there;
#   2. the stubs are generated from the STRIPPED copy, which is the only form protoc-gen-ng
#      produces usable output for.
#
# presence.pb.ts is committed as the generator produced it, WITHOUT the codemod applied: it is
# the input the bats suite runs the codemod over.

IMAGE=ondewo-angular-proto-compiler:latest
FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "---------------------------------------------------------------"
echo "Regenerating the proto3 presence fixtures from presence.proto ..."
echo "---------------------------------------------------------------"

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$FIXTURE_DIR":/fixture \
  --entrypoint bash \
  "$IMAGE" -c '
set -e
cd /image-data
work=$(mktemp -d)
cp /fixture/presence.proto "$work/presence.proto"
protoc --descriptor_set_out=/fixture/presence.descriptor.bin -I "$work" "$work/presence.proto"
sed -i.bak "s/^\([[:space:]]*\)optional /\1/" "$work/presence.proto" && rm -f "$work/presence.proto.bak"
protoc \
  --plugin=protoc-gen-ng=./node_modules/.bin/protoc-gen-ng \
  --ng_out=/fixture \
  -I "$work" \
  "$work/presence.proto"
'

echo "---------------------------------------------------------------"
echo "✅ Regenerated presence.descriptor.bin and presence.pb.ts"
echo "---------------------------------------------------------------"
