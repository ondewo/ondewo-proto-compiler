#!/usr/bin/env sh

# This script updates the ondewo-nlu-client-python dependency in the REPO_DIR project

# --- Usage Check ---
if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <version> <programming_language> <node_version> <repo>" >&2
  exit 1
fi

VERSION=$1
PROGRAMMING_LANGUAGE=$2
NODE_VERSION=$3
REPO=$4

# =============================================
# Script to update ondewo-proto-compiler version
# =============================================
CLEAN_UP="${CLEAN_UP:-true}"
REPO_DIR=$REPO-$PROGRAMMING_LANGUAGE

set -eu  # Exit on error and treat unset variables as an error

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# --- Portable colored logging (echo does not interpret \033 escapes under all /bin/sh) ---
log() { printf '%b\n' "$*"; }

# ONDEWO_TMP_DIR="/tmp/ondewo-$(date '+%Y%m%d_%H%M%S_%3N')"
ONDEWO_TMP_DIR="${ONDEWO_TMP_DIR:-/tmp/ondewo}"
TMP_DIR="${ONDEWO_TMP_DIR}/${REPO_DIR}"

log "${BLUE}[INFO]${NC} Updating ${REPO_DIR} to use ondewo-proto-compiler version: ${GREEN}${VERSION}${NC}"

if [ ! -d "$ONDEWO_TMP_DIR" ]; then
  log "${YELLOW}[WARN]${NC} Temporary directory ${ONDEWO_TMP_DIR} does not exist, creating it..."
  mkdir -p "$ONDEWO_TMP_DIR"
fi

# --- Navigate to temp directory ---
cd "$ONDEWO_TMP_DIR" || {
  log "${RED}[ERROR]${NC} Failed to change to ${ONDEWO_TMP_DIR} directory."
  exit 1
}

# --- Clean up existing clone if present ---
if [ -d "$TMP_DIR" ]; then
  log "${YELLOW}[WARN]${NC} Removing existing temporary directory: ${TMP_DIR}"
  rm -rf "${TMP_DIR:?}"
fi

# --- Clone repository ---
log "${BLUE}[INFO]${NC} Cloning repository: git@github.com:ondewo/${REPO_DIR}.git"
git clone "git@github.com:ondewo/${REPO_DIR}.git"


# --- Checkout the desired version ---
cd "$REPO_DIR" || {
  log "${RED}[ERROR]${NC} Cannot enter repository directory: $REPO_DIR"
  exit 1
}

# --- Node-family clients (and only those) ship a node-based Dockerfile.utils carrying ENV NODE_VERSION.
# The php/go/rust/cpp/java/csharp clients have no node toolchain, so the NODE_VERSION rewrite below and the
# package.json merge further down both key off this single definition rather than drifting apart.
IS_NODE_FAMILY=false
case "$PROGRAMMING_LANGUAGE" in
  angular|typescript|nodejs|js) IS_NODE_FAMILY=true ;;
esac

# --- Set NODE_VERSION in Dockerfile.utils from environment variable ---
if [ "$IS_NODE_FAMILY" = "false" ]; then
  log "${YELLOW}[SKIP]${NC} '$PROGRAMMING_LANGUAGE' has no node toolchain - not touching Dockerfile.utils"
elif [ -f "Dockerfile.utils" ]; then
  if [ -z "${NODE_VERSION:-}" ]; then
    log "${RED}[ERROR]${NC} NODE_VERSION environment variable is not set"
    exit 1
  fi
  # -i.bak (not bare -i) keeps this working with both GNU and BSD/macOS sed
  sed -i.bak "s/^ENV NODE_VERSION=.*/ENV NODE_VERSION=${NODE_VERSION}/" Dockerfile.utils
  rm -f Dockerfile.utils.bak
  git add Dockerfile.utils
  if ! git diff --cached --quiet; then
    git commit -m "Set NODE_VERSION to ${NODE_VERSION} in Dockerfile.utils"
    git push
    log "${BLUE}[INFO]${NC} Set NODE_VERSION in Dockerfile.utils to ${NODE_VERSION}"
  else
    log "${YELLOW}[NOOP]${NC} No changes to commit for Dockerfile.utils."
  fi
else
  log "${RED}[ERROR]${NC} Dockerfile.utils not found in ondewo-proto-compiler directory"
  exit 1
fi

log "${BLUE}[INFO]${NC} Updating submodules..."
git submodule update --init --recursive

cd "ondewo-proto-compiler" || {
  log "${RED}[ERROR]${NC} Cannot enter submodule directory: ondewo-proto-compiler"
  exit 1
}
log "${BLUE}[INFO]${NC} Checking out version: ${GREEN}${VERSION}${NC}"
git checkout "$VERSION"

cd ..

# --- Update the dependency in the project ---
if [ "$IS_NODE_FAMILY" = "true" ]; then

  if [ "$PROGRAMMING_LANGUAGE" = "js" ]; then
    IMAGE_DATA_PKG="ondewo-proto-compiler/js/image-data/default-lib-files/package.json"
  else
    IMAGE_DATA_PKG="ondewo-proto-compiler/${PROGRAMMING_LANGUAGE}/image-data/package.json"
  fi

  TARGET_PKG="src/package.json"

  log "${BLUE}[INFO]${NC} Updating $TARGET_PKG from $IMAGE_DATA_PKG"

  if [ ! -f "$IMAGE_DATA_PKG" ]; then
    log "${RED}[ERROR]${NC} Missing source package.json: $IMAGE_DATA_PKG"
    exit 1
  fi

  if [ ! -f "$TARGET_PKG" ]; then
    log "${RED}[ERROR]${NC} Missing target package.json: $TARGET_PKG"
    exit 1
  fi

  IMAGE_DEPS=$(jq -c '[
    .dependencies // {},
    .devDependencies // {},
    .peerDependencies // {}
  ] | add' "$IMAGE_DATA_PKG") || { log "${RED}[ERROR]${NC} Failed to parse $IMAGE_DATA_PKG" >&2; exit 1; }

  # Explicit template: BSD/macOS mktemp requires a trailing run of X's (bare
  # `mktemp` with no operand errors there); GNU accepts the same template.
  TMP_PKG=$(mktemp "${TMPDIR:-/tmp}/proto-compiler.XXXXXX")
  trap 'rm -f "$TMP_PKG"' EXIT
  log "${BLUE}[INFO]${NC} Updating only existing dependency versions..."

  # NOT an `jq ... && mv ...` AND-OR list: `set -e` is specified to ignore the failure of
  # every command of such a list except the last, so a failing jq would be swallowed and the
  # script would go on to commit and push a manifest it never updated.
  if ! jq --argjson imageDeps "$IMAGE_DEPS" '
    def update_existing(section):
      if .[section] then
        .[section] |= with_entries(
          if $imageDeps[.key] then
            .value = $imageDeps[.key]
          else
            .
          end
        )
        | if (.[section] | length == 0) then del(.[section]) else . end
      else
        .
      end;

    update_existing("dependencies") |
    update_existing("devDependencies") |
    update_existing("peerDependencies")
  ' "$TARGET_PKG" > "$TMP_PKG"; then
    log "${RED}[ERROR]${NC} Failed to update dependency versions in $TARGET_PKG - leaving it untouched" >&2
    exit 1
  fi

  # jq exits 0 and writes nothing for an empty or whitespace-only input, so the exit status
  # alone would still let a 0-byte package.json be installed, committed and pushed.
  if [ ! -s "$TMP_PKG" ]; then
    log "${RED}[ERROR]${NC} Refusing to install an empty $TARGET_PKG (is $IMAGE_DATA_PKG / $TARGET_PKG valid JSON?)" >&2
    exit 1
  fi

  mv "$TMP_PKG" "$TARGET_PKG"

  if [ -n "$TARGET_PKG" ]; then
    log "${BLUE}[INFO]${NC} Adding updated package.json to staging area: ${TARGET_PKG} ..."
    git add "${TARGET_PKG}"
  fi

else
  log "${YELLOW}[WARN]${NC} Programming language '$PROGRAMMING_LANGUAGE' does not require package.json update."
fi

# --- Point the client's own pin at the release too. Moving only the submodule gitlink leaves
# ONDEWO_PROTO_COMPILER_GIT_BRANCH naming the PREVIOUS release, and the client's
# update_submodules target then checks that older ref back out - silently undoing this bump.
if [ -f "Makefile" ] && grep -q '^ONDEWO_PROTO_COMPILER_GIT_BRANCH=' Makefile; then
  # -i.bak (not bare -i) keeps this working with both GNU and BSD/macOS sed
  sed -i.bak "s|^ONDEWO_PROTO_COMPILER_GIT_BRANCH=.*|ONDEWO_PROTO_COMPILER_GIT_BRANCH=tags/${VERSION}|" Makefile
  rm -f Makefile.bak
  git add Makefile
  log "${BLUE}[INFO]${NC} Set ONDEWO_PROTO_COMPILER_GIT_BRANCH to tags/${VERSION} in Makefile"
else
  log "${YELLOW}[SKIP]${NC} No ONDEWO_PROTO_COMPILER_GIT_BRANCH in Makefile - nothing to repin"
fi

log "${BLUE}[INFO]${NC} Diff of updated git repo ${REPO_DIR}:"
git --no-pager diff .


log "${BLUE}[INFO]${NC} Adding ondewo-proto-compiler submodule..."
git add ondewo-proto-compiler

if ! git diff --cached --quiet; then
  log "${BLUE}[INFO]${NC} Changes detected, preparing to commit..."
  log "${BLUE}[INFO]${NC} Committing version update..."
  git commit -m "Update proto compiler dependency to version $VERSION"
  log "${BLUE}[INFO]${NC} Pushing to remote..."
  git push
  log "${GREEN}[SUCCESS]${NC} Updated $REPO_DIR dependency to ondewo-proto-compiler to version $VERSION."
else
  log "${YELLOW}[NOOP]${NC} No changes to commit."
fi

# --- Cleanup ---
if [ "${CLEAN_UP:-true}" = "true" ]; then
  log "${BLUE}[INFO]${NC} Cleaning up temporary files for ${TMP_DIR} ..."
  rm -rf "${TMP_DIR:?}"
  log "${GREEN}[DONE]${NC} Update process completed successfully for ${TMP_DIR}."
else
  log "${YELLOW}[SKIP]${NC} Skipping cleanup as per user request."
fi
