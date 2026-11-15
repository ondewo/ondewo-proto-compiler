#!/bin/sh
# Client-SDK matrix cell for the php target: regenerate an ondewo-<product>-client-php checkout IN PLACE
# with the prebuilt ondewo-php-proto-compiler:latest image and prove the result works.
#
#   sh tests/client-matrix/php.sh <client_dir>
#
# <client_dir> is a checked-out client repo with its submodules initialised (recursively). It is mutated:
# src/, vendor/, composer.json/.lock and tools/vendor/ are rewritten.
#
# The generate step is the client's own `make generate_ondewo_protos`, with PROTO_COMPILER_IMAGE pointed at
# the prebuilt image. The three recipe shapes in use (nlu: --user, input = output = repo root; csi/sip/vtsi:
# --user, read-only api + composer.json mounts, staged output copied back; s2t/t2s/survey: root, input =
# output = repo root) and the per-product api dir therefore come from the client itself. The recipe is
# dry-run first (`make -n`) and refused unless it only runs that image - no docker build, git, sudo or -it.
# survey's nested googleapis/ include root is detected by the compiler image itself.
#
# Verification: no root-owned output is left, src/ is non-empty, every committed stub comes back, then the
# client's own gate - `make install_dependencies install_dev_tools` followed by `make test` (composer
# validate, Packagist dry run, php -l, check_build against the api submodule, PHPUnit with the 100% coverage
# gate incl. the real TLS handshake test) - and a smoke check that loads vendor/autoload.php, initialises
# every GPBMetadata descriptor and instantiates every generated *Client class.
#
# Host tools: docker, make, git, perl, awk, php >= 8.1 with ext-grpc, ext-bcmath and pcov, composer 2,
# python3 with grpcio (the client's TLS test server), network (packagist for composer update).
set -eu

IMAGE="ondewo-php-proto-compiler:latest"

fail() {
  echo "❌ ERROR: $*" >&2
  exit 1
}

banner() {
  echo "---------------------------------------------------------------"
  echo "$*"
  echo "---------------------------------------------------------------"
}

[ "$#" -eq 1 ] || fail "usage: sh $0 <client_dir>"
[ -d "$1" ] || fail "client dir '$1' is not a directory"
CLIENT_DIR="$(cd "$1" && pwd)"
NAME="$(basename "${CLIENT_DIR}")"

for tool in docker make git perl awk php composer python3; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${NAME}: required host tool '${tool}' is not on PATH"
done
for ext in grpc bcmath pcov; do
  php -r "exit(extension_loaded('${ext}') ? 0 : 1);" || fail "${NAME}: php extension '${ext}' is not loaded"
done
python3 -c 'import grpc' 2>/dev/null || fail "${NAME}: python3 cannot import grpc - pip install grpcio (TLS test server)"
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || fail "docker image '${IMAGE}' is not built - run: docker build -t ${IMAGE} <ondewo-proto-compiler>/php"

cd "${CLIENT_DIR}"
for f in Makefile composer.json phpunit.xml.dist tools/composer.json; do
  [ -f "${f}" ] || fail "${NAME}: '${f}' not found in ${CLIENT_DIR}"
done
[ -d auth ] || fail "${NAME}: no hand-written 'auth/' dir in ${CLIENT_DIR}"
[ -d tests ] || fail "${NAME}: no 'tests/' dir in ${CLIENT_DIR} - no client test suite to run"
for target in generate_ondewo_protos install_dependencies install_dev_tools test; do
  grep -q "^${target}:" Makefile || fail "${NAME}: Makefile has no '${target}' target"
done
uninit="$(git submodule status --recursive | grep -c '^-' || true)"
[ "${uninit}" -eq 0 ] || fail "${NAME}: ${uninit} submodule(s) not initialised - run: git submodule update --init --recursive"

# The api submodule is the client's `ondewo-*-api` submodule; its ondewo/ tree is what gets compiled.
API_DIR="$(sed -n 's|^[[:space:]]*path[[:space:]]*=[[:space:]]*\(ondewo-[A-Za-z0-9]*-api\)[[:space:]]*$|\1|p' .gitmodules | head -n 1)"
[ -n "${API_DIR}" ] || fail "${NAME}: no 'ondewo-*-api' submodule in .gitmodules"
[ -d "${API_DIR}/ondewo" ] || fail "${NAME}: '${API_DIR}/ondewo' is missing - is the api submodule initialised?"
PROTO_COUNT="$(find "./${API_DIR}/ondewo" -type f -name '*.proto' | grep -c . || true)"
[ "${PROTO_COUNT}" -gt 0 ] || fail "${NAME}: no .proto files under ${API_DIR}/ondewo"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/client-matrix-php.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
trap 'exit 130' INT TERM

banner "PHP [${NAME}]: Starting .proto to grpc client stubs generation (${PROTO_COUNT} protos of ${API_DIR}) ..."

make -s -n generate_ondewo_protos PROTO_COMPILER_IMAGE="${IMAGE}" >"${WORK}/recipe" 2>"${WORK}/recipe.err" \
  || { cat "${WORK}/recipe.err" >&2; fail "${NAME}: 'make -n generate_ondewo_protos' failed"; }
awk '/\\$/ { sub(/\\$/, ""); buf = buf $0; next } { print buf $0; buf = "" }' "${WORK}/recipe" >"${WORK}/lines"
grep -F 'docker run' "${WORK}/lines" | grep -F "${IMAGE}" | grep -q "[[:space:]]${IMAGE}[[:space:]]" \
  || fail "${NAME}: generate_ondewo_protos does not 'docker run' ${IMAGE}:$(cat "${WORK}/lines")"
if grep -E 'docker (build|push|pull)|(^|[[:space:];&|])(git|sudo|curl)[[:space:]]|[[:space:]]-it[[:space:]]' "${WORK}/lines"; then
  fail "${NAME}: generate_ondewo_protos does more than run the compiler image (line above) - refusing to run it"
fi
echo ">>> make generate_ondewo_protos PROTO_COMPILER_IMAGE=${IMAGE}"
cat "${WORK}/lines"

git ls-files -- src >"${WORK}/committed"
committed="$(grep -c . "${WORK}/committed" || true)"
[ "${committed}" -gt 0 ] || fail "${NAME}: no committed stubs under src/ - nothing to compare against"

# Wipe the committed stubs so the assertions below see only what this run generated.
rm -rf src vendor
make generate_ondewo_protos PROTO_COMPILER_IMAGE="${IMAGE}" || fail "${NAME}: make generate_ondewo_protos failed"

# Three of the clients run the image as root: never leave root-owned output behind.
if [ -n "$(find . -path ./.git -prune -o ! -user "$(id -u)" -print | head -n 1)" ]; then
  echo "output not owned by $(id -u) - fixing ownership"
  docker run --rm -v "${CLIENT_DIR}:/w" alpine chown -R "$(id -u):$(id -g)" /w || fail "${NAME}: chown failed"
fi

banner "✅ PHP [${NAME}]: Done .proto to grpc client stubs generation"

banner "PHP [${NAME}]: Verifying the generated stubs ..."

[ -d src ] || fail "${NAME}: the compiler wrote no src/"
generated="$(find ./src -type f -name '*.php' | grep -c . || true)"
[ "${generated}" -gt 0 ] || fail "${NAME}: the compiler generated no .php files under src/"
clients="$(find ./src -type f -name '*Client.php' | grep -c . || true)"
[ "${clients}" -gt 0 ] || fail "${NAME}: the compiler generated no *Client.php service stub"
echo "generated .php files: ${generated} (committed: ${committed}), service clients: ${clients}"

missing=0
while IFS= read -r f; do
  [ -f "${f}" ] || { echo "MISSING (committed but not regenerated): ${f}" >&2; missing=$((missing + 1)); }
done <"${WORK}/committed"
[ "${missing}" -eq 0 ] || fail "${NAME}: ${missing} committed stub(s) were not regenerated"
php -r '$j = json_decode(file_get_contents("composer.json"), true); exit(in_array("auth/", $j["autoload"]["classmap"] ?? [], true) ? 0 : 1);' || fail "${NAME}: the regenerated composer.json lost 'auth/' from its classmap"

changed="$(git status --porcelain -- src | grep -c . || true)"
echo "stub files differing from the committed ones (informational): ${changed}"

banner "PHP [${NAME}]: Installing dependencies + dev tools (make install_dependencies install_dev_tools) ..."
make install_dependencies install_dev_tools || fail "${NAME}: make install_dependencies install_dev_tools failed"

banner "PHP [${NAME}]: Smoke check - autoload, every descriptor, every service client ..."
php -d error_reporting=E_ALL -d display_errors=stderr -r '
require "vendor/autoload.php";
$it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator("src", FilesystemIterator::SKIP_DOTS));
$meta = 0; $stubs = 0;
foreach ($it as $file) {
    if ($file->getExtension() !== "php") { continue; }
    $code = file_get_contents($file->getPathname());
    if (!preg_match("/^namespace[[:space:]]+([^;]+);/m", $code, $ns) || !preg_match("/^(?:final[[:space:]]+)?class[[:space:]]+(\w+)/m", $code, $cl)) { continue; }
    $class = "\\" . $ns[1] . "\\" . $cl[1];
    if (!class_exists($class)) { fwrite(STDERR, "class does not autoload: $class\n"); exit(1); }
    if (strpos($ns[1], "GPBMetadata") === 0) { $class::initOnce(); $meta++; }
    if (substr($cl[1], -6) === "Client" && is_subclass_of($class, "Grpc\\BaseStub")) {
        $c = new $class("localhost:1", ["credentials" => Grpc\ChannelCredentials::createInsecure()]);
        $c->close(); $stubs++;
    }
}
if ($meta === 0 || $stubs === 0) { fwrite(STDERR, "smoke check found $meta descriptors, $stubs service clients\n"); exit(1); }
echo "initialised $meta descriptors, instantiated $stubs service clients\n";
' || fail "${NAME}: smoke check failed - the generated package does not load"

banner "PHP [${NAME}]: Running the client's test suite (make test) ..."
make test || fail "${NAME}: make test failed"

banner "✅ PHP [${NAME}]: generated ${generated} files from ${PROTO_COUNT} protos, smoke check + make test passed"
