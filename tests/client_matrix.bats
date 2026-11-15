#!/usr/bin/env bats
# Fast guards for the client-SDK matrix (tests/client-matrix/ + .github/workflows/client-matrix.yml):
# every language in the workflow matrix has a cell script, every script refuses a bad call before it
# touches docker, and the matrix covers all seven products.

load 'helpers/setup'

setup() {
  common_setup
  WORKFLOW="$REPO_ROOT/.github/workflows/client-matrix.yml"
  LANGS="$(sed -n 's/^[[:space:]]*lang: \[\(.*\)\]$/\1/p' "$WORKFLOW" | tr -d ' ' | tr ',' ' ')"
}

teardown() { common_teardown; }

@test "workflow: the matrix covers angular, js, nodejs, python and php" {
  [ "$LANGS" = "angular js nodejs python php" ]
}

@test "workflow: the matrix covers all seven products" {
  products="$(sed -n 's/^[[:space:]]*product: \[\(.*\)\]$/\1/p' "$WORKFLOW" | tr -d ' ')"
  [ "$products" = "nlu,csi,sip,vtsi,s2t,t2s,survey" ]
}

@test "workflow: every matrix language has a cell script and an image directory" {
  for lang in $LANGS; do
    [ -f "$REPO_ROOT/tests/client-matrix/$lang.sh" ] || { echo "no tests/client-matrix/$lang.sh"; return 1; }
    [ -f "$REPO_ROOT/$lang/Dockerfile" ] || { echo "no $lang/Dockerfile"; return 1; }
  done
}

@test "scripts: every cell script exits non-zero with a usage message and never calls docker without a client dir" {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  for lang in $LANGS; do
    run sh "$REPO_ROOT/tests/client-matrix/$lang.sh"
    [ "$status" -ne 0 ] || { echo "$lang: exit 0 without args"; return 1; }
    [[ "$output" == *"usage"* ]] || { echo "$lang: $output"; return 1; }
    run sh "$REPO_ROOT/tests/client-matrix/$lang.sh" "$SANDBOX/missing"
    [ "$status" -ne 0 ] || { echo "$lang: exit 0 on a missing dir"; return 1; }
  done
  [ ! -s "$DOCKER_MOCK_LOG" ]
}
