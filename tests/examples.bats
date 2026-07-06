#!/usr/bin/env bats
# Tests for the example run-compile.sh scripts with a PATH-mock docker. Proves
# the mount path is built correctly and quoted (js-7) and that the dir is
# resolved without the doubled-path bug when invoked via an absolute path
# (node-3). The scripts are copied into the sandbox so the real repo tree is not
# polluted with a generated lib/ dir.

load 'helpers/setup'

setup() {
  common_setup
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
}
teardown() { common_teardown; }

@test "js-7: js example builds a well-formed -v mount from its own dir" {
  cp "$REPO_ROOT/js/example/run-compile.sh" "$SANDBOX/run.sh"
  run bash "$SANDBOX/run.sh"
  [ "$status" -eq 0 ]
  run grep -Fq -- "-v $SANDBOX:/input-volume" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/lib" ]
}

@test "node-3: nodejs example resolves its dir correctly via absolute invocation" {
  cp "$REPO_ROOT/nodejs/example/run-compile.sh" "$SANDBOX/run.sh"
  run bash "$SANDBOX/run.sh"
  [ "$status" -eq 0 ]
  run grep -Fq -- "-v $SANDBOX:/input-volume" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  # no doubled path (the old `$(pwd)/`dirname $0`` bug)
  run grep -Fq -- "-v $SANDBOX/$SANDBOX" "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "typescript example builds a well-formed -v mount and creates lib/" {
  cp "$REPO_ROOT/typescript/example/run-compile.sh" "$SANDBOX/run.sh"
  run bash "$SANDBOX/run.sh"
  [ "$status" -eq 0 ]
  run grep -Fq -- "-v $SANDBOX:/input-volume" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/lib" ]
}
