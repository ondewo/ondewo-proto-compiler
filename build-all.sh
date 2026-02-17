#!/bin/sh
echo "##########################################################"
echo "Start building all ondewo-proto-compilers docker images ..."
echo "##########################################################"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for lang in python angular js nodejs typescript; do
  echo ""
  echo ">>> Building ${lang} ..."
  cd "${SCRIPT_DIR}/${lang}" && bash build.sh
  echo ">>> ${lang} build complete."
done

echo "##########################################################"
echo "✅ Building all ondewo-proto-compilers docker images."
echo "##########################################################"
