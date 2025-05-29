#!/usr/bin/env sh

# This script updates the ondewo-nlu-client-python dependency in the REPO_DIR project
VERSION=$1
REPO_DIR=$2

# =============================================
# Script to update ondewo-proto-compiler version
# =============================================

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

TMP_DIR="/tmp/$REPO_DIR"

echo "${BLUE}[INFO]${NC} Updating ${REPO_DIR} to use ondewo-proto-compiler version: ${GREEN}${VERSION}${NC}"

# --- Navigate to temp directory ---
cd /tmp || {
  echo "${RED}[ERROR]${NC} Failed to change to /tmp directory."
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
echo "${BLUE}[INFO]${NC} Updating submodules..."
git submodule update --init --recursive

cd "ondewo-proto-compiler" || {
  echo "${RED}[ERROR]${NC} Cannot enter submodule directory: ondewo-proto-compiler"
  exit 1
}
echo "${BLUE}[INFO]${NC} Checking out version tag: ${GREEN}${VERSION}${NC}"
git checkout "tags/$VERSION"

cd ..

# --- Commit and push changes if any ---
git add "ondewo-proto-compiler"
if ! git diff --cached --quiet; then
  echo "${BLUE}[INFO]${NC} Committing version update..."
  git commit -m "Update proto compiler dependency to version $VERSION"
  echo "${BLUE}[INFO]${NC} Pushing to remote..."
  git push
  echo "${GREEN}[SUCCESS]${NC} Updated $REPO_DIR dependency to ondewo-proto-compiler to version $VERSION."
else
  echo "${YELLOW}[NOOP]${NC} No changes to commit."
fi
