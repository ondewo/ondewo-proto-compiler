#!/bin/sh
set -e
echo "##########################################################"
echo "Start building all ondewo-proto-compilers docker images ..."
echo "##########################################################"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for lang in python angular js nodejs typescript; do
  echo ""
  echo ">>> Building ${lang} ..."
  cd "${SCRIPT_DIR}/${lang}" || { echo "❌ missing dir ${lang}" >&2; exit 1; }
  bash build.sh || { echo "❌ ${lang} build FAILED" >&2; exit 1; }
  echo ">>> ${lang} build complete."
done

echo "##########################################################"
echo "✅ Building all ondewo-proto-compilers docker images."
echo "##########################################################"
