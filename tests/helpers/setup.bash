#!/usr/bin/env bash
# Shared setup helpers for the bats suite.
#
# The scripts under test call external tools (git, docker, protoc, python, ...).
# Tests prepend tests/helpers/bin to PATH so those calls hit controllable mocks
# that log their argv and return configurable exit codes, letting us assert on
# behaviour without Docker, network, or a real protoc toolchain.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
MOCK_BIN="$TESTS_DIR/helpers/bin"
FIXTURES="$TESTS_DIR/fixtures"

# Create an isolated sandbox dir and put the mock bins first on PATH.
common_setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/otc.XXXXXX")"
  PATH="$MOCK_BIN:$PATH"
  export PATH SANDBOX REPO_ROOT TESTS_DIR FIXTURES
}

common_teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  return 0
}

# Every tracked shell script the shellcheck gate must lint: the *.sh/*.bash
# sources plus the extension-less PATH-mock tools under tests/helpers/bin, which
# are shell scripts too. Emitted space-separated for intentional word splitting.
# Must be run from REPO_ROOT so the git globs resolve.
tracked_shell_scripts() {
  git ls-files '*.sh' '*.bash' 'tests/helpers/bin/*'
}
