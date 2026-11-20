#!/bin/sh
# Real code generation in every compiler image: `make test_real_generation`.
# Usage: run.sh [<language> ...]   (default: all eleven)
#
# The bats suite mocks protoc and every toolchain, so it cannot tell whether an image still
# generates code that compiles and loads against the runtime it pins. This script runs each
# BUILT image on a small proto set (the target's own example, the python test protos, or the
# angular compat fixture), then compiles or imports the output inside the same image and checks
# the generator version stamped into it against the Makefile.
#
# Images: ondewo-<language>-proto-compiler:${REAL_GENERATION_TAG:-latest} - build them first
# (`make build`, or `docker build -t ondewo-<language>-proto-compiler:<tag> <language>`).
# Needs Docker; the js, typescript and nodejs runs `npm install` their output (network).
# Outputs are kept under ${REAL_GENERATION_WORK_DIR:-a new temp dir} for inspection.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TAG="${REAL_GENERATION_TAG:-latest}"
WORK_DIR="${REAL_GENERATION_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/real-generation.XXXXXX")}"
LANGUAGES="python java csharp php go rust cpp js typescript nodejs angular"
if [ "$#" -gt 0 ]; then LANGUAGES="$*"; fi
UID_GID="$(id -u):$(id -g)"
FAILED=""

mk() {
  sed -n "s|^$1=||p" "$ROOT/Makefile" | head -n 1
}

image() {
  printf 'ondewo-%s-proto-compiler:%s' "$1" "$TAG"
}

# in_image <language> <shell command>: run a shell command in the language image, in its output dir
in_image() {
  docker run --rm --entrypoint sh -v "$WORK_DIR/$1/out":/w -w /w "$(image "$1")" -c "$2"
}

# generate <language> <input dir> <entrypoint args...>: the codegen run, as a client runs it
generate() {
  lang=$1
  input=$2
  shift 2
  rm -rf "${WORK_DIR:?}/$lang"
  mkdir -p "$WORK_DIR/$lang/out"
  docker run --rm -v "$input":/input-volume:ro -v "$WORK_DIR/$lang/out":/output-volume "$(image "$lang")" "$@" \
    > "$WORK_DIR/$lang/generate.log" 2>&1
}

# stamped <language> <file glob relative to out/> <fixed string>: the generator stamp is present
stamped() {
  # the needle travels as an environment value: it may itself contain quotes
  docker run --rm --entrypoint sh -e NEEDLE="$3" -v "$WORK_DIR/$1/out":/w -w /w "$(image "$1")" \
    -c "grep -rqF -- \"\$NEEDLE\" $2" || {
    echo "the output carries no '$3' (expected in $2)" >&2
    return 1
  }
}

check_python() {
  mkdir -p "$WORK_DIR/python/out"
  docker run --rm --user "$UID_GID" \
    -v "$ROOT/python/protos":/home/ondewo/ondewo-proto-compiler/protos/protos:ro \
    -v "$WORK_DIR/python/out":/home/ondewo/ondewo-proto-compiler/output \
    "$(image python)" > "$WORK_DIR/python/generate.log" 2>&1 || return 1
  stamped python 'protos/test_pb2_grpc.py' "GRPC_GENERATED_VERSION = '$(mk PYTHON_GRPCIO_VERSION)'" &&
    stamped python 'protos/test_pb2.py' "# Protobuf Python Version: 7.$(mk PROTOC_VERSION)" &&
    docker run --rm --entrypoint python -v "$WORK_DIR/python/out":/w -w /w "$(image python)" -c '
from protos import test_pb2, test_import_pb2, test_import_pb2_grpc
m = test_import_pb2.AnotherTest(name="x", test=test_pb2.Test(name="y"))
assert test_import_pb2.AnotherTest.FromString(m.SerializeToString()).test.name == "y"
assert test_import_pb2_grpc.AnotherServiceStub and test_import_pb2_grpc.AnotherServiceServicer
print("python: stubs import and round-trip")'
}

check_java() {
  generate java "$ROOT/java/example" protos || return 1
  stamped java 'src' "Protobuf Java Version: 4.$(mk PROTOC_VERSION)" &&
    stamped java 'pom.xml' "<grpc.version>$(mk GRPC_JAVA_VERSION)</grpc.version>" &&
    in_image java 'ls target/*.jar && unzip -l target/ondewo-proto-stubs-java-*[0-9].jar | grep -F SimpleServiceGrpc.class'
}

check_csharp() {
  generate csharp "$ROOT/csharp/example" protos "" Ondewo.Example.Client || return 1
  in_image csharp 'ls artifacts/*/Ondewo.Example.Client.dll nupkg/Ondewo.Example.Client.*.nupkg' &&
    in_image csharp "unzip -p nupkg/Ondewo.Example.Client.*[0-9].nupkg '*.nuspec' | grep -F 'id=\"Google.Protobuf\" version=\"$(mk GOOGLE_PROTOBUF_VERSION)\"'"
}

check_php() {
  generate php "$ROOT/php/example" protos || return 1
  in_image php 'ls src/Ondewo/Example/SimpleServiceClient.php' &&
    in_image php "grep -A1 '\"name\": \"google/protobuf\"' composer.lock | grep -F '\"v$(mk GOOGLE_PROTOBUF_PHP_VERSION)\"'" &&
    in_image php 'php -r '"'"'require "vendor/autoload.php"; $t = new \Ondewo\Example\Test(); $t->setName("x");
      $u = new \Ondewo\Example\Test(); $u->mergeFromString($t->serializeToString());
      if ($u->getName() !== "x") { exit(1); } echo "php: messages load and round-trip\n";'"'"
}

check_go() {
  generate go "$ROOT/go/example" protos "" github.com/ondewo/ondewo-proto-compiler-go-example || return 1
  stamped go 'api' "protoc-gen-go v$(mk PROTOC_GEN_GO_VERSION)" &&
    in_image go "grep -F 'google.golang.org/grpc v$(mk GRPC_GO_VERSION)' go.mod && go vet ./... && go build ./..."
}

check_rust() {
  generate rust "$ROOT/rust/example" protos || return 1
  in_image rust "grep -A1 '^name = \"prost\"$' Cargo.lock && cargo build --offline --quiet && echo 'rust: crate builds offline'"
}

check_cpp() {
  generate cpp "$ROOT/cpp/example" protos . ondewo_example_client || return 1
  in_image cpp 'find . -name "libondewo_example_client*" -type f | grep .'
}

check_js() {
  generate js "$ROOT/js/example" myfancylibrary || return 1
  in_image js "grep -qF 'SimpleServiceClient' myfancylibrary.js && grep -qF 'grpc-web v$(mk GRPC_WEB_VERSION)' myfancylibrary.js && ls myfancylibrary.min.js"
}

check_typescript() {
  generate typescript "$ROOT/typescript/example" protos library || return 1
  stamped typescript 'api' "protoc-gen-grpc-web v$(mk GRPC_WEB_VERSION)" &&
    in_image typescript "node -e \"
const pb = require('./api/library/test_pb.js');
const web = require('./api/library/test_grpc_web_pb.js');
const t = new pb.Test(); t.setName('x');
if (pb.Test.deserializeBinary(t.serializeBinary()).getName() !== 'x' || !web.SimpleServicePromiseClient) process.exit(1);
console.log('typescript: stubs load against grpc-web ' + require('grpc-web/package.json').version);\""
}

check_nodejs() {
  generate nodejs "$ROOT/nodejs/example" protos library || return 1
  in_image nodejs "node -e \"
const api = require('./public-api.js');
const t = new api.Test(); t.setName('x');
if (api.Test.deserializeBinary(t.serializeBinary()).getName() !== 'x' || typeof api.SimpleServiceClient !== 'function') process.exit(1);
const v = (p) => require(p + '/package.json').version;
console.log('nodejs: stubs load against @grpc/grpc-js ' + v('@grpc/grpc-js') + ', google-protobuf ' + v('google-protobuf'));
if (v('google-protobuf') !== '$(mk NODEJS_GOOGLE_PROTOBUF_VERSION)') process.exit(1);\""
}

check_angular() {
  generate angular "$ROOT/tests/angular-compat/fixture-client" protos ondewo || return 1
  in_image angular 'ls npm/package.json && ls npm/fesm2022/*.mjs'
}

echo "---------------------------------------------------------------"
echo "Real generation: images tagged '$TAG', work dir $WORK_DIR"
echo "---------------------------------------------------------------"
for lang in $LANGUAGES; do
  echo "--- $lang ($(image "$lang"))"
  if "check_$lang"; then
    echo "✅ $lang"
  else
    echo "❌ $lang (generation log: $WORK_DIR/$lang/generate.log)" >&2
    FAILED="$FAILED $lang"
  fi
  # the node, go, rust, ... images run as root: hand the output back to the caller
  if [ -d "$WORK_DIR/$lang/out" ]; then
    in_image "$lang" "chown -R $UID_GID /w" > /dev/null 2>&1 || true
  fi
done

echo "---------------------------------------------------------------"
if [ -n "$FAILED" ]; then
  echo "❌ Real generation failed for:$FAILED"
  echo "---------------------------------------------------------------"
  exit 1
fi
echo "✅ Real generation: $LANGUAGES"
echo "---------------------------------------------------------------"
