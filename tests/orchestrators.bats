#!/usr/bin/env bats
# Tests for build-all.sh and the per-language build.sh wrappers with a PATH-mock
# docker. Proves the silent-failure fixes: a failing `docker build` now
# propagates a non-zero exit instead of the trailing success echo masking it
# (orch-1, orch-2). No images are built.

load 'helpers/setup'

setup() {
  common_setup
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
}
teardown() { common_teardown; }

@test "orch-1: a language build.sh propagates docker build failure" {
  FAIL_BUILD_MATCH="ondewo-angular-proto-compiler" run sh "$REPO_ROOT/angular/build.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"✅"* ]]
}

@test "orch-1: build.sh exits 0 when docker build succeeds" {
  run sh "$REPO_ROOT/js/build.sh"
  [ "$status" -eq 0 ]
}

@test "orch-2: build-all.sh fails when any single image build fails" {
  FAIL_BUILD_MATCH="ondewo-js-proto-compiler" run bash "$REPO_ROOT/build-all.sh"
  [ "$status" -ne 0 ]
  # must NOT reach the final all-images-built success banner
  [[ "$output" != *"Building all ondewo-proto-compilers docker images."* ]]
}

@test "orch-2: build-all.sh exits 0 and builds all five images when docker succeeds" {
  run bash "$REPO_ROOT/build-all.sh"
  [ "$status" -eq 0 ]
  for lang in python angular js nodejs typescript; do
    run grep -c "ondewo-${lang}-proto-compiler" "$DOCKER_MOCK_LOG"
    [ "$output" -ge 1 ]
  done
}
