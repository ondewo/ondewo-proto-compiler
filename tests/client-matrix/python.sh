#!/bin/sh
# Client-SDK matrix cell: regenerate an ondewo-<product>-client-python checkout IN PLACE with the prebuilt
# ondewo-python-proto-compiler:latest image and prove the result works.
#
#   sh tests/client-matrix/python.sh <client_dir>
#
# <client_dir> is a checked-out client repo with its submodules initialised (recursively). It is mutated:
# every committed *_pb2*.py / *_pb2*.pyi is deleted and regenerated.
#
# The generate step is read from the client's own Makefile (`generate_all_protos`, else
# `generate_ondewo_protos`) with `make -n`, so per-product differences (api dir name, survey's googleapis/,
# csi's ondewo/csi target, vtsi's six target dirs, an absent EXTRA_PROTO_DIR) come from the client itself.
# Of that recipe only the `make -f ondewo-proto-compiler/python/Makefile run ...` calls are replayed, against
# THIS repo's python/Makefile; the client's pre-commit reformat runs are not (they need the network and do
# not change what the stubs mean).
#
# Verification: every committed stub comes back, each _pb2.py has its _pb2_grpc.py + _pb2.pyi, nothing is
# left un-owned by the caller, every generated module imports, `python -m compileall` passes, and the
# client's CI gate runs (uv sync --frozen, ruff, mypy, pytest on the unit suite).
#
# Host tools: docker, make, git, uv (uv provides the python interpreter; set UV_PYTHON to pin it).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPILER_MAKEFILE="${REPO_ROOT}/python/Makefile"
# PYTHON_COMPILER_IMAGE overrides the image (default: the tag every client build uses).
IMAGE="${PYTHON_COMPILER_IMAGE:-ondewo-python-proto-compiler:latest}"

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

for tool in docker make git uv; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${NAME}: required host tool '${tool}' is not on PATH"
done
[ -f "${COMPILER_MAKEFILE}" ] || fail "compiler Makefile '${COMPILER_MAKEFILE}' not found"
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
  || fail "docker image '${IMAGE}' is not built - run: docker build -t ${IMAGE} ${REPO_ROOT}/python"

cd "${CLIENT_DIR}"
for f in Makefile pyproject.toml uv.lock; do
  [ -f "${f}" ] || fail "${NAME}: '${f}' not found in ${CLIENT_DIR}"
done
[ -d ondewo ] || fail "${NAME}: no 'ondewo/' package dir in ${CLIENT_DIR}"
uninit="$(git submodule status --recursive | grep -c '^-' || true)"
[ "${uninit}" -eq 0 ] || fail "${NAME}: ${uninit} submodule(s) not initialised - run: git submodule update --init --recursive"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/client-matrix-python.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
trap 'exit 130' INT TERM

banner "Python [${NAME}]: Starting .proto to grpc client stubs generation ..."

if grep -q '^generate_all_protos:' Makefile; then
  gen_target=generate_all_protos
elif grep -q '^generate_ondewo_protos:' Makefile; then
  gen_target=generate_ondewo_protos
else
  fail "${NAME}: Makefile has neither a 'generate_all_protos' nor a 'generate_ondewo_protos' target"
fi

# `make -n` prints recipe lines with variables expanded but backslash continuations kept; join them, then keep
# only the compiler `run` invocations and their argument tail.
make -s -n "${gen_target}" >"${WORK}/recipe" 2>"${WORK}/recipe.err" \
  || { cat "${WORK}/recipe.err" >&2; fail "${NAME}: 'make -n ${gen_target}' failed"; }
awk '/\\$/ { sub(/\\$/, ""); buf = buf $0; next } { print buf $0; buf = "" }' "${WORK}/recipe" \
  | grep -F 'ondewo-proto-compiler/python/Makefile run' \
  | sed 's|^.*ondewo-proto-compiler/python/Makefile run||' >"${WORK}/runs" || true
runs="$(grep -c . "${WORK}/runs" || true)"
[ "${runs}" -gt 0 ] || fail "${NAME}: '${gen_target}' invokes no 'make -f ondewo-proto-compiler/python/Makefile run'"
echo "${gen_target}: ${runs} compiler run(s)"

git ls-files -- 'ondewo/*_pb2.py' 'ondewo/*_pb2_grpc.py' 'ondewo/*_pb2.pyi' 'ondewo/*_pb2_grpc.pyi' >"${WORK}/committed"
committed="$(grep -c . "${WORK}/committed" || true)"
[ "${committed}" -gt 0 ] || fail "${NAME}: no committed *_pb2* stubs under ondewo/ - nothing to compare against"

# Delete every stub so the assertions below see only what this run generated.
find ./ondewo -type f \( -name '*_pb2.py' -o -name '*_pb2_grpc.py' -o -name '*_pb2.pyi' -o -name '*_pb2_grpc.pyi' \) \
  -exec rm -f {} +

while IFS= read -r args; do
  echo ">>> make -f python/Makefile run IMAGE_NAME=${IMAGE}${args}"
  # The tail is the client's own expanded Makefile text (it carries its quoting), hence eval.
  eval "make -f \"\${COMPILER_MAKEFILE}\" run IMAGE_NAME=\"\${IMAGE}\" ${args}" || fail "${NAME}: compiler run failed:${args}"
done <"${WORK}/runs"

banner "✅ Python [${NAME}]: Done .proto to grpc client stubs generation"

banner "Python [${NAME}]: Verifying the generated stubs ..."

# The python image runs as the caller (--user), but never leave root-owned output behind either way.
if [ -n "$(find ./ondewo ! -user "$(id -u)" -print | head -n 1)" ]; then
  echo "WARNING: output not owned by $(id -u) - fixing ownership"
  docker run --rm -v "${CLIENT_DIR}:/w" alpine chown -R "$(id -u):$(id -g)" /w
fi

find ./ondewo -type f \( -name '*_pb2.py' -o -name '*_pb2_grpc.py' -o -name '*_pb2.pyi' -o -name '*_pb2_grpc.pyi' \) \
  | sed 's|^\./||' | sort >"${WORK}/generated"
generated="$(grep -c . "${WORK}/generated" || true)"
[ "${generated}" -gt 0 ] || fail "${NAME}: the compiler generated no stub files"
echo "generated stub files: ${generated} (committed: ${committed})"

missing=0
while IFS= read -r f; do
  [ -f "${f}" ] || { echo "MISSING (committed but not regenerated): ${f}" >&2; missing=$((missing + 1)); }
done <"${WORK}/committed"
[ "${missing}" -eq 0 ] || fail "${NAME}: ${missing} committed stub(s) were not regenerated"

incomplete=0
grep '_pb2\.py$' "${WORK}/generated" >"${WORK}/pb2" || true
protos="$(grep -c . "${WORK}/pb2" || true)"
while IFS= read -r f; do
  base="${f%_pb2.py}"
  for sib in "${base}_pb2_grpc.py" "${base}_pb2.pyi"; do
    [ -f "${sib}" ] || { echo "INCOMPLETE: ${f} has no ${sib}" >&2; incomplete=$((incomplete + 1)); }
  done
done <"${WORK}/pb2"
[ "${incomplete}" -eq 0 ] || fail "${NAME}: ${incomplete} stub sibling(s) missing"
echo "protos compiled: ${protos} (3 files each)"

changed="$(git status --porcelain -- ondewo | grep -c . || true)"
echo "stub files differing from the committed ones (informational): ${changed}"

banner "Python [${NAME}]: Installing the client (uv sync --extra dev --frozen) ..."
uv sync --extra dev --frozen || fail "${NAME}: uv sync failed"

banner "Python [${NAME}]: Smoke check - import every generated module + compileall ..."
grep '_pb2\(_grpc\)\{0,1\}\.py$' "${WORK}/generated" | sed 's|\.py$||; s|/|.|g' >"${WORK}/modules"
uv run --frozen python - "${WORK}/modules" <<'EOF' || fail "${NAME}: generated modules do not import"
import importlib
import sys
import traceback

with open(sys.argv[1]) as fh:
    modules = [line.strip() for line in fh if line.strip()]
failed = 0
for name in modules:
    try:
        importlib.import_module(name)
    except Exception:
        failed += 1
        print("IMPORT FAILED: " + name, file=sys.stderr)
        traceback.print_exc()
print("imported %d/%d generated modules" % (len(modules) - failed, len(modules)))
sys.exit(1 if failed or not modules else 0)
EOF
uv run --frozen python -m compileall -q ondewo >/dev/null || fail "${NAME}: python -m compileall ondewo failed"
echo "compileall: ok"

if [ -d tests/unit ]; then
  unit_dir=tests/unit
elif [ -d test/unit ]; then
  unit_dir=test/unit
else
  fail "${NAME}: no unit test dir (tests/unit or test/unit)"
fi

banner "Python [${NAME}]: Running the client's CI gate (ruff, mypy, pytest ${unit_dir}) ..."
uv run --frozen ruff check . || fail "${NAME}: ruff check failed"
uv run --frozen mypy ondewo || fail "${NAME}: mypy ondewo failed"
uv run --frozen pytest "${unit_dir}" -q || fail "${NAME}: pytest ${unit_dir} failed"

banner "✅ Python [${NAME}]: generated ${generated} stub files from ${protos} protos, imports + client tests pass"
