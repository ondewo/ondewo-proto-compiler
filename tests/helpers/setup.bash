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

# Wipe the toolchain environment a developer's or CI runner's shell is likely to
# carry (CARGO_HOME, GOPATH/GOMODCACHE, NUGET_PACKAGES, DOTNET_CLI_HOME,
# COMPOSER_CACHE_DIR, MAVEN_OPTS, JAVA_HOME, CMAKE_BUILD_PARALLEL_LEVEL, ...).
# Many of those names are ALSO the knobs the image-data scripts read
# (MAVEN_REPO_LOCAL, CARGO_REGISTRY_HOME, NUGET_OFFLINE_FEED, GRPC_CPP_PLUGIN,
# PROTOC, OndewoTargetFramework, ...), so an ambient value would silently
# redirect a build out of the sandbox and make a test's outcome depend on the
# machine it runs on. Everything in those namespaces goes, except the mock
# layer's own knobs (*_MOCK_LOG / *_MOCK_RC / *_FAIL_MATCH / *_FAIL_RC), which a
# test sets AFTER calling common_setup anyway.
scrub_toolchain_env() {
  local leaked
  # shellcheck disable=SC2086  # intentional word splitting of the prefix-matched name lists
  for leaked in ${!CARGO_@} ${!RUST@} ${!GO@} ${!COMPOSER_@} ${!PHP_@} \
                ${!MAVEN_@} ${!M2_@} ${!JAVA_@} ${!NUGET_@} ${!DOTNET_@} \
                ${!MSBUILD@} ${!CMAKE_@} ${!GRPC_@} ${!PROTOC@} \
                ${!ONDEWO_@} ${!Ondewo@}; do
    case "$leaked" in
      *_MOCK_LOG|*_MOCK_RC|*_MOCK_STDIN_LOG|*_FAIL_MATCH|*_FAIL_RC) continue ;;
    esac
    unset "$leaked"
  done
  # Script knobs that match none of the prefixes above. The container-path
  # overrides matter most: an ambient value would send a pipeline's rm -rf and
  # its output at a real directory instead of the sandbox.
  unset IMAGE_DATA_DIRECTORY INPUT_VOLUME_FS OUTPUT_VOLUME_FS TEMP_SRC_DIRECTORY \
        DEFAULT_FILES_DIR BUILD_DIRECTORY INSTALL_DIRECTORY CRATE_DIRECTORY \
        DIST_DIRECTORY SKIP_CARGO_BUILD
}

# Create an isolated sandbox dir and put the mock bins first on PATH.
common_setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/otc.XXXXXX")"
  PATH="$MOCK_BIN:$PATH"
  scrub_toolchain_env
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
