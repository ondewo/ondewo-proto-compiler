#!/usr/bin/env sh

# This script updates the ondewo-nlu-client-python dependency in the REPO_DIR project
VERSION=$1
PROGRAMMING_LANGUAGE=$2
NODE_VERSION=$3
REPO=$4

# =============================================
# Script to update ondewo-proto-compiler version
# =============================================
CLEAN_UP="true"
REPO_DIR=$REPO-$PROGRAMMING_LANGUAGE

set -eu  # Exit on error and treat unset variables as an error

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# --- Usage Check ---
if [ $# -lt 2 ]; then
  echo "${YELLOW}Usage: $0 <version> <repo_dir>${NC}"
  exit 1
fi

# ONDEWO_TMP_DIR="/tmp/ondewo-$(date '+%Y%m%d_%H%M%S_%3N')"
ONDEWO_TMP_DIR="/tmp/ondewo"
TMP_DIR="${ONDEWO_TMP_DIR}/${REPO_DIR}"

echo "${BLUE}[INFO]${NC} Updating ${REPO_DIR} to use ondewo-proto-compiler version: ${GREEN}${VERSION}${NC}"

if [ ! -d "$ONDEWO_TMP_DIR" ]; then
  echo "${YELLOW}[WARN]${NC} Temporary directory ${ONDEWO_TMP_DIR} does not exist, creating it..."
  mkdir -p "$ONDEWO_TMP_DIR"
fi

# --- Navigate to temp directory ---
cd /tmp/ondewo || {
  echo "${RED}[ERROR]${NC} Failed to change to ${TMP_DIR} directory."
  exit 1
}

# --- Clean up existing clone if present ---
if [ -d "$TMP_DIR" ]; then
  echo "${YELLOW}[WARN]${NC} Removing existing temporary directory: ${TMP_DIR}"
  rm -rf "$TMP_DIR"
fi

# --- Clone or update repository ---
if [ ! -d "$REPO_DIR" ]; then
  echo "${BLUE}[INFO]${NC} Cloning repository: git@github.com:ondewo/${REPO_DIR}.git"
  git clone "git@github.com:ondewo/${REPO_DIR}.git"
else
  echo "${BLUE}[INFO]${NC} Repository already exists, fetching latest changes..."
  cd "$REPO_DIR"
  git fetch --all
  cd ..
fi


# --- Checkout the desired version ---
cd "$REPO_DIR" || {
  echo "${RED}[ERROR]${NC} Cannot enter repository directory: $REPO_DIR"
  exit 1
}

# --- Set NODE_VERSION in Dockerfile.utils from environment variable ---
if [ -f "Dockerfile.utils" ]; then
  if [ -z "${NODE_VERSION:-}" ]; then
    echo "${RED}[ERROR]${NC} NODE_VERSION environment variable is not set"
    exit 1
  fi
  sed -i "s/^ENV NODE_VERSION=.*/ENV NODE_VERSION=${NODE_VERSION}/" Dockerfile.utils
  git add Dockerfile.utils
  if ! git diff --cached --quiet; then
    git commit -m "Set NODE_VERSION to ${NODE_VERSION} in Dockerfile.utils"
    git push
    echo "${BLUE}[INFO]${NC} Set NODE_VERSION in Dockerfile.utils to ${NODE_VERSION}"
  else
    echo "${YELLOW}[NOOP]${NC} No changes to commit for Dockerfile.utils."
  fi
else
  echo "${RED}[ERROR]${NC} Dockerfile.utils not found in ondewo-proto-compiler directory"
  exit 1
fi

echo "${BLUE}[INFO]${NC} Updating submodules..."
git submodule update --init --recursive

cd "ondewo-proto-compiler" || {
  echo "${RED}[ERROR]${NC} Cannot enter submodule directory: ondewo-proto-compiler"
  exit 1
}
echo "${BLUE}[INFO]${NC} Checking out version: ${GREEN}${VERSION}${NC}"
git checkout "$VERSION"

cd ..

# --- Update the dependency in the project ---
if [ "$PROGRAMMING_LANGUAGE" = "angular" ] || \
   [ "$PROGRAMMING_LANGUAGE" = "typescript" ] || \
   [ "$PROGRAMMING_LANGUAGE" = "js" ]; then

  if [ "$PROGRAMMING_LANGUAGE" = "angular" ] || [ "$PROGRAMMING_LANGUAGE" = "typescript" ]; then
    IMAGE_DATA_PKG="ondewo-proto-compiler/${PROGRAMMING_LANGUAGE}/image-data/package.json"
  else
    IMAGE_DATA_PKG="ondewo-proto-compiler/${PROGRAMMING_LANGUAGE}/image-data/default-lib-files/package.json"
  fi

  TARGET_PKG="src/package.json"

  echo "${BLUE}[INFO]${NC} Updating $TARGET_PKG from $IMAGE_DATA_PKG"

  if [ ! -f "$IMAGE_DATA_PKG" ]; then
    echo "${RED}[ERROR]${NC} Missing source package.json: $IMAGE_DATA_PKG"
    exit 1
  fi

  if [ ! -f "$TARGET_PKG" ]; then
    echo "${RED}[ERROR]${NC} Missing target package.json: $TARGET_PKG"
    exit 1
  fi

  IMAGE_DEPS=$(jq -c '[
    .dependencies // {},
    .devDependencies // {},
    .peerDependencies // {}
  ] | add' "$IMAGE_DATA_PKG") || IMAGE_DEPS="{}"

  TMP_PKG=$(mktemp)
  echo "${BLUE}[INFO]${NC} Updating only existing dependency versions..."

  jq --argjson imageDeps "$IMAGE_DEPS" '
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
  ' "$TARGET_PKG" > "$TMP_PKG" && mv "$TMP_PKG" "$TARGET_PKG"

  if [ -n "$TARGET_PKG" ]; then
    echo "${BLUE}[INFO]${NC} Adding updated package.json to staging area: ${TARGET_PKG} ..."
    git add "${TARGET_PKG}"
  fi

else
  echo "${YELLOW}[WARN]${NC} Programming language '$PROGRAMMING_LANGUAGE' does not require package.json update."
fi

echo "${BLUE}[INFO]${NC} Diff of updated git repo ${REPO_DIR}:"
git --no-pager diff .


echo "${BLUE}[INFO]${NC} Adding ondewo-proto-compiler submodule..."
git add ondewo-proto-compiler

if ! git diff --cached --quiet; then
  echo "${BLUE}[INFO]${NC} Changes detected, preparing to commit..."
  echo "${BLUE}[INFO]${NC} Committing version update..."
  git commit -m "Update proto compiler dependency to version $VERSION"
  echo "${BLUE}[INFO]${NC} Pushing to remote..."
  git push
  echo "${GREEN}[SUCCESS]${NC} Updated $REPO_DIR dependency to ondewo-proto-compiler to version $VERSION."
else
  echo "${YELLOW}[NOOP]${NC} No changes to commit."
fi

# --- Cleanup ---
if [ "${CLEAN_UP:-true}" = "true" ]; then
  echo "${BLUE}[INFO]${NC} Cleaning up temporary files for ${TMP_DIR} ..."
  rm -rf "${TMP_DIR}"
  echo "${GREEN}[DONE]${NC} Update process completed successfully for ${TMP_DIR}."
else
  echo "${YELLOW}[SKIP]${NC} Skipping cleanup as per user request."
fi
