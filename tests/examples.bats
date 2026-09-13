#!/usr/bin/env bats
# Tests for the example run-compile.sh scripts with a PATH-mock docker. Proves
# the mount path is built correctly and quoted (js-7), that the dir is resolved
# without the doubled-path bug when invoked via an absolute path (node-3), and -
# for all eleven targets - that the codegen `docker run` carries no -it, which
# breaks every non-interactive caller with "cannot attach stdin to a TTY-enabled
# container". The scripts are copied into the sandbox so the real repo tree is
# not polluted with a generated lib/ dir.

load 'helpers/setup'

setup() {
  common_setup
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
}
teardown() { common_teardown; }

# Discovery goes through the filesystem, NOT `git ls-files`: common_setup puts
# the PATH mocks first and the mock git answers `ls-files` with silence, which
# would turn every loop below into a vacuous pass.
example_targets() {
  local d
  for d in "$REPO_ROOT"/*/; do
    d="${d%/}"
    if [ -f "$d/example/run-compile.sh" ]; then echo "${d##*/}"; fi
  done | sort
}

# Copy one target's example into its own sandbox dir and run it with no args
# (the codegen branch; the -it debug branch is the `$1` given branch). Echoes
# the sandbox dir it ran from.
run_example() {
  local lang="$1" d
  d="$SANDBOX/$lang"
  mkdir -p "$d"
  cp "$REPO_ROOT/$lang/example/run-compile.sh" "$d/run.sh"
  : > "$DOCKER_MOCK_LOG"
  bash "$d/run.sh"
}

log_has() {   # <literal>
  if grep -Fq -- "$1" "$DOCKER_MOCK_LOG"; then return 0; fi
  echo "MISSING from the docker log: $1"
  echo "--- docker log ---"; cat "$DOCKER_MOCK_LOG"
  return 1
}

log_lacks() { # <literal>
  if grep -Fq -- "$1" "$DOCKER_MOCK_LOG"; then
    echo "UNEXPECTED in the docker log: $1"
    echo "--- docker log ---"; cat "$DOCKER_MOCK_LOG"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# named regressions
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# every target that ships an example
# ---------------------------------------------------------------------------

@test "every example mounts its own dir in and its own lib/ out" {
  local lang d checked=0
  for lang in $(example_targets); do
    checked=$((checked + 1))
    d="$SANDBOX/$lang"
    run run_example "$lang"
    echo "$lang exited $status: $output"
    [ "$status" -eq 0 ]

    log_has "-v $d:/input-volume"
    log_has "-v $d/lib:/output-volume"
    log_has "ondewo-${lang}-proto-compiler"
    [ -d "$d/lib" ]
    # the dir is the script's own, resolved without the doubled-path bug
    log_lacks "-v $d$d"
    log_lacks "-v .:"
    # exactly one container run per example
    [ "$(grep -c '^docker run' "$DOCKER_MOCK_LOG")" -eq 1 ]
  done
  # the nine targets that ship an example today; guards an empty discovery
  [ "$checked" -ge 9 ]
}

@test "no -it on the codegen docker run in any example" {
  # -it belongs on the `--entrypoint /bin/bash` debug branch only: on the
  # codegen call it fails with "cannot attach stdin to a TTY-enabled container
  # because stdin is not a terminal" for every non-interactive caller (CI, make,
  # a client's npm script).
  local lang checked=0
  for lang in $(example_targets); do
    checked=$((checked + 1))
    run run_example "$lang"
    [ "$status" -eq 0 ]
    echo "$lang: $(cat "$DOCKER_MOCK_LOG")"
    run grep -Eq -- '(^|[[:space:]])(-it|-ti|-i[[:space:]]+-t|-t[[:space:]]+-i)([[:space:]]|$)' "$DOCKER_MOCK_LOG"
    [ "$status" -ne 0 ]
  done
  [ "$checked" -ge 9 ]
}

@test "every example quotes the -v mount operands it passes to docker" {
  # `-v $FILEDIRECTORY:/input-volume` unquoted word-splits the moment a client
  # checks the repo out under a path with a space in it (js-7).
  local lang checked=0
  for lang in $(example_targets); do
    checked=$((checked + 1))
    run bash -c "grep -nE -- '-v[[:space:]]+\\\$' '$REPO_ROOT/$lang/example/run-compile.sh' | grep -vE '^[0-9]+:[[:space:]]*#'"
    echo "$lang: unquoted -v operand: $output"
    [ -z "$output" ]
  done
  [ "$checked" -ge 9 ]
}
