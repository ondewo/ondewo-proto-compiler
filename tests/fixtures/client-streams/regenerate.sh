#!/bin/sh
set -e

# Regenerate the client-streams fixture artifacts from streams.proto.
#
#   sh tests/fixtures/client-streams/regenerate.sh
#
# Runs inside the angular compiler image (build it first with `make build_angular`), so the
# fixtures come from the SAME protoc the pipeline uses:
#
#   streams.request.bin - the CodeGeneratorRequest protoc hands to the angular plugin, captured by a
#   plugin that only copies its stdin. It is the input the bats suite runs
#   omit-client-streaming-methods.js over.

IMAGE="${IMAGE:-ondewo-angular-proto-compiler:latest}"
FIXTURE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "---------------------------------------------------------------"
echo "Regenerating the client-streams fixtures from streams.proto ..."
echo "---------------------------------------------------------------"

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$FIXTURE_DIR":/fixture \
  --entrypoint bash \
  "$IMAGE" -c '
set -e
cd /image-data
work=$(mktemp -d "${TMPDIR:-/tmp}/client-streams-fixture.XXXXXX")
cp /fixture/streams.proto "$work/streams.proto"
printf "#!/bin/sh\ncat > /fixture/streams.request.bin\n" > "$work/protoc-gen-capture"
chmod +x "$work/protoc-gen-capture"
protoc --plugin=protoc-gen-capture="$work/protoc-gen-capture" --capture_out="$work" -I "$work" "$work/streams.proto"
'

echo "---------------------------------------------------------------"
echo "✅ Regenerated streams.request.bin"
echo "---------------------------------------------------------------"
