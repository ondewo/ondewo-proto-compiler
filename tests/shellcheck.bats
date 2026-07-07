#!/usr/bin/env bats
# Static-analysis gate: every tracked shell script must pass shellcheck. This is
# the mechanical correctness layer (unquoted vars, missing shebangs, unguarded
# cd, legacy constructs) and runs as part of `make test` and in CI.
#
# NOTE: these tests deliberately do NOT use common_setup — they need the REAL
# git/shellcheck on PATH, not the release-test mocks.

load 'helpers/setup'

@test "shellcheck gate: all tracked shell scripts pass at -S warning" {
  cd "$REPO_ROOT"
  run shellcheck -x -S warning $(tracked_shell_scripts)
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "no script is missing a shebang (SC2148 == 0)" {
  cd "$REPO_ROOT"
  run shellcheck -x -f gcc $(tracked_shell_scripts)
  echo "$output"
  n=$(printf '%s\n' "$output" | grep -c 'SC2148' || true)
  [ "$n" -eq 0 ]
}

@test "every cd is guarded (SC2164 == 0)" {
  cd "$REPO_ROOT"
  run shellcheck -x -f gcc $(tracked_shell_scripts)
  echo "$output"
  n=$(printf '%s\n' "$output" | grep -c 'SC2164' || true)
  [ "$n" -eq 0 ]
}
