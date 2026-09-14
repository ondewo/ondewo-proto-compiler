#!/usr/bin/env bats
# Hardening tests for update_proto_compiler_dependency.sh: the package.json rewrite
# must never hand a client repo a manifest it did not actually produce.
#
# The rewrite used to be an AND-OR list -- `jq ... > "$TMP_PKG" && mv "$TMP_PKG" "$TARGET_PKG"`.
# `set -e` is specified to ignore the failure of every command of an AND-OR list except the
# last one (verify: `bash -c 'set -e; false && echo x; echo reached'` prints "reached"), so a
# failing jq was swallowed: the script logged [SUCCESS] and committed + pushed a manifest that
# still pinned the old versions. And because `>` truncates the temp file before jq ever runs,
# an input jq accepts but produces no output for (an empty / whitespace-only manifest) had its
# 0-byte result moved onto the client's package.json and pushed.
#
# A local PATH-mock jq (built per test, so tests/helpers/bin stays untouched) forces the
# failure path; the empty-manifest case runs against the REAL jq.

load 'helpers/setup'

SCRIPT="update_proto_compiler_dependency.sh"

setup() {
  common_setup
  export ONDEWO_TMP_DIR="$SANDBOX/ondewo"
  export CAPTURE_DIR="$SANDBOX/capture"
  export CLEAN_UP=false
  mkdir -p "$CAPTURE_DIR"
  # Private copy of the typescript client fixture, so a test can corrupt it freely.
  FIXTURE="$SANDBOX/fixture"
  mkdir -p "$FIXTURE"
  cp -r "$FIXTURES/client-repos/typescript/." "$FIXTURE/"
}

teardown() { common_teardown; }

# Put a jq wrapper first on PATH that fails (with the given exit code, writing nothing)
# on the dependency-merge call -- the only one passing --argjson -- and delegates every
# other call to the real jq.
mock_failing_merge_jq() {
  local rc="${1:-5}" real
  real="$(command -v jq)"
  mkdir -p "$SANDBOX/mockbin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$a" = "--argjson" ]; then\n'
    printf '    echo "mock jq: simulated merge failure" >&2\n'
    printf '    exit %s\n' "$rc"
    printf '  fi\n'
    printf 'done\n'
    printf 'exec %s "$@"\n' "$real"
  } > "$SANDBOX/mockbin/jq"
  chmod +x "$SANDBOX/mockbin/jq"
  PATH="$SANDBOX/mockbin:$PATH"
  export PATH
}

run_update() {
  REPO_FIXTURE="$FIXTURE" run sh "$REPO_ROOT/$SCRIPT" "$@"
}

@test "rel-5: a failing jq merge aborts loudly instead of being swallowed by the AND-OR list" {
  mock_failing_merge_jq 5
  run_update 9.9.9 typescript 24.14.0 ondewo-nlu-client
  [ "$status" -ne 0 ]
  # the failure names the file it refused to touch
  [[ "$output" == *"[ERROR]"* ]]
  [[ "$output" == *"src/package.json"* ]]
  # and it must not claim to have released anything
  [[ "$output" != *"[SUCCESS]"* ]]
  [[ "$output" != *"Pushing to remote"* ]]
}

@test "rel-5: a failing jq merge leaves the client's package.json byte-for-byte intact" {
  mock_failing_merge_jq 5
  run_update 9.9.9 typescript 24.14.0 ondewo-nlu-client
  [ "$status" -ne 0 ]
  clone="$ONDEWO_TMP_DIR/ondewo-nlu-client-typescript/src/package.json"
  run cmp -s "$clone" "$FIXTURES/client-repos/typescript/src/package.json"
  [ "$status" -eq 0 ]
  # nothing was staged, so nothing could be committed or pushed
  [ ! -f "$CAPTURE_DIR/src/package.json" ]
}

@test "rel-5: an empty target package.json is never installed, committed or pushed" {
  # Real jq: it exits 0 and writes NOTHING for an empty input, so an exit-status check
  # alone still moves a 0-byte file onto the client's manifest.
  : > "$FIXTURE/src/package.json"
  run_update 9.9.9 typescript 24.14.0 ondewo-nlu-client
  [ "$status" -ne 0 ]
  [[ "$output" == *"[ERROR]"* ]]
  [[ "$output" == *"empty"* ]]
  [[ "$output" != *"[SUCCESS]"* ]]
  [[ "$output" != *"Pushing to remote"* ]]
  [ ! -f "$CAPTURE_DIR/src/package.json" ]
}

@test "rel-5: the temp file is not left behind after an aborted merge" {
  mock_failing_merge_jq 5
  TMPDIR="$SANDBOX/tmp"
  mkdir -p "$TMPDIR"
  export TMPDIR
  run_update 9.9.9 typescript 24.14.0 ondewo-nlu-client
  [ "$status" -ne 0 ]
  run bash -c "find '$SANDBOX/tmp' -name 'proto-compiler.*' | grep -c . || true"
  [ "$output" = "0" ]
}

@test "rel-5: the guard does not false-trip on a healthy merge" {
  run_update 9.9.9 typescript 24.14.0 ondewo-nlu-client
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SUCCESS]"* ]]
  [[ "$output" != *"[ERROR]"* ]]
  run jq -r '.dependencies["google-protobuf"]' "$CAPTURE_DIR/src/package.json"
  [ "$output" = "9.9.9" ]
}
