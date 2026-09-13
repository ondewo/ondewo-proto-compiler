#!/usr/bin/env bats
# Tests for update_proto_compiler_dependency.sh (release automation), run OUTSIDE
# Docker with a PATH-mock git and real jq/sed/cp. Covers rel-1 (arg guard),
# rel-2 (nodejs now bumped), rel-3 (jq failure fails loudly), and the happy-path
# version bump / Dockerfile.utils NODE_VERSION rewrite.

load 'helpers/setup'

SCRIPT="update_proto_compiler_dependency.sh"

setup() {
  common_setup
  export ONDEWO_TMP_DIR="$SANDBOX/ondewo"
  export CAPTURE_DIR="$SANDBOX/capture"
  export GIT_MOCK_LOG="$SANDBOX/git.log"
  export CLEAN_UP=false
  mkdir -p "$CAPTURE_DIR"
}

teardown() { common_teardown; }

# Run the script: run_update <version> <lang> <node_version> <repo> [fixture]
run_update() {
  local fixture="${5:-$FIXTURES/client-repos/$2}"
  REPO_FIXTURE="$fixture" run sh "$REPO_ROOT/$SCRIPT" "$1" "$2" "$3" "$4"
}

@test "rel-1: fewer than 4 args is rejected with a usage message" {
  run sh "$REPO_ROOT/$SCRIPT" 5.9.0 typescript
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "rel-1: exactly 4 args is accepted (guard does not false-trip)" {
  run_update 5.9.0 typescript 24.14.0 ondewo-nlu-client
  [ "$status" -eq 0 ]
}

@test "happy path: existing dep bumped, unrelated dep untouched, NODE_VERSION rewritten" {
  run_update 5.9.0 typescript 24.14.0 ondewo-nlu-client
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SUCCESS]"* ]]
  # google-protobuf bumped 0.0.1 -> 9.9.9 (from the image-data source)
  run jq -r '.dependencies["google-protobuf"]' "$CAPTURE_DIR/src/package.json"
  [ "$output" = "9.9.9" ]
  # unrelated dep left alone
  run jq -r '.dependencies.rxjs' "$CAPTURE_DIR/src/package.json"
  [ "$output" = "7.0.0" ]
  # Dockerfile.utils NODE_VERSION rewritten to the passed value
  run grep -c '^ENV NODE_VERSION=24.14.0$' "$CAPTURE_DIR/Dockerfile.utils"
  [ "$output" -eq 1 ]
}

@test "typescript reads the image-data/package.json source" {
  run_update 5.9.0 typescript 24.14.0 ondewo-nlu-client
  [[ "$output" == *"typescript/image-data/package.json"* ]]
}

@test "js reads the default-lib-files/package.json source" {
  run_update 5.9.0 js 24.14.0 ondewo-nlu-client
  [ "$status" -eq 0 ]
  [[ "$output" == *"js/image-data/default-lib-files/package.json"* ]]
  run jq -r '.dependencies["google-protobuf"]' "$CAPTURE_DIR/src/package.json"
  [ "$output" = "9.9.9" ]
}

@test "rel-2: nodejs is now bumped like the other JS-family targets" {
  run_update 5.9.0 nodejs 24.14.0 ondewo-nlu-client
  [ "$status" -eq 0 ]
  # it must NOT take the 'does not require package.json update' branch
  [[ "$output" != *"does not require package.json update"* ]]
  run jq -r '.dependencies["google-protobuf"]' "$CAPTURE_DIR/src/package.json"
  [ "$output" = "9.9.9" ]
}

@test "rel-3: a corrupt source package.json fails loudly (no silent success)" {
  run_update 5.9.0 typescript 24.14.0 ondewo-nlu-client "$FIXTURES/client-repos/corrupt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to parse"* ]]
  [[ "$output" != *"[SUCCESS]"* ]]
  # the bump never happened -> no captured target file
  [ ! -f "$CAPTURE_DIR/src/package.json" ]
}

@test "rel-4: the client's ONDEWO_PROTO_COMPILER_GIT_BRANCH is repinned to the new tag" {
  # Moving only the submodule gitlink leaves the client's own pin naming the PREVIOUS
  # release, and its update_submodules target then checks that older ref back out -
  # silently undoing the bump. Both have to move together.
  fixture="$SANDBOX/repo"
  mkdir -p "$fixture/ondewo-proto-compiler"
  printf 'ONDEWO_NLU_VERSION=7.1.0\nONDEWO_PROTO_COMPILER_GIT_BRANCH=tags/5.14.0\n' > "$fixture/Makefile"
  printf 'ENV NODE_VERSION=20.0.0\n' > "$fixture/Dockerfile.utils"

  REPO_FIXTURE="$fixture" CAPTURE_DIR="$SANDBOX/staged" \
    run sh "$REPO_ROOT/update_proto_compiler_dependency.sh" 9.9.9 python 24.14.0 ondewo-nlu-client
  echo "$output"
  [ "$status" -eq 0 ]
  run grep -Fxq "ONDEWO_PROTO_COMPILER_GIT_BRANCH=tags/9.9.9" "$SANDBOX/staged/Makefile"
  [ "$status" -eq 0 ]
  # the unrelated variable is untouched
  run grep -Fxq "ONDEWO_NLU_VERSION=7.1.0" "$SANDBOX/staged/Makefile"
  [ "$status" -eq 0 ]
  # portable in-place edit leaves no backup behind
  run bash -c "find '$SANDBOX' -name 'Makefile.bak' | grep -c ."
  [ "$output" = "0" ]
}

@test "rel-4: a client Makefile without the pin is left alone, not corrupted" {
  fixture="$SANDBOX/repo"
  mkdir -p "$fixture/ondewo-proto-compiler"
  printf 'ONDEWO_NLU_VERSION=7.1.0\n' > "$fixture/Makefile"
  printf 'ENV NODE_VERSION=20.0.0\n' > "$fixture/Dockerfile.utils"

  REPO_FIXTURE="$fixture" CAPTURE_DIR="$SANDBOX/staged" \
    run sh "$REPO_ROOT/update_proto_compiler_dependency.sh" 9.9.9 python 24.14.0 ondewo-nlu-client
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to repin"* ]]
}
