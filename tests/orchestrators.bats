#!/usr/bin/env bats
# Tests for build-all.sh and the per-language build.sh wrappers with a PATH-mock
# docker. Proves the silent-failure fixes: a failing `docker build` now
# propagates a non-zero exit instead of the trailing success echo masking it
# (orch-1, orch-2), and that the eleven-target fan-out is complete - every
# language image is built, with its own tag, from its own directory. No images
# are built.

load 'helpers/setup'

setup() {
  common_setup
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
}
teardown() { common_teardown; }

# Discovery goes through the filesystem, NOT `git ls-files`: common_setup puts
# the PATH mocks first and the mock git answers `ls-files` with silence, which
# would turn every loop below into a vacuous pass.
lang_targets() {
  local d
  for d in "$REPO_ROOT"/*/; do
    d="${d%/}"
    if [ -f "$d/build.sh" ] && [ -f "$d/Dockerfile" ]; then echo "${d##*/}"; fi
  done | sort
}

# The languages build-all.sh iterates, in its own build order.
build_all_languages() {
  local w
  for w in $(sed -n 's|^for lang in \(.*\); do$|\1|p' "$REPO_ROOT/build-all.sh"); do
    echo "$w"
  done
}

# The language of every `docker build -t ondewo-<lang>-proto-compiler:latest`
# the mock recorded, in call order.
built_languages() {
  sed -n 's|^docker build --no-cache -t ondewo-\([a-z0-9]*\)-proto-compiler:latest .*|\1|p' "$DOCKER_MOCK_LOG"
}

# ---------------------------------------------------------------------------
# per-language build.sh
# ---------------------------------------------------------------------------

@test "orch-1: a language build.sh propagates docker build failure" {
  FAIL_BUILD_MATCH="ondewo-angular-proto-compiler" run sh "$REPO_ROOT/angular/build.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"✅"* ]]
}

@test "orch-1: build.sh exits 0 when docker build succeeds" {
  run sh "$REPO_ROOT/js/build.sh"
  [ "$status" -eq 0 ]
}

@test "orch-1: every language build.sh tags its own image and builds its own directory" {
  local lang checked=0
  for lang in $(lang_targets); do
    checked=$((checked + 1))
    : > "$DOCKER_MOCK_LOG"
    run sh "$REPO_ROOT/$lang/build.sh"
    echo "$lang exited $status: $output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"✅"* ]]
    # the tag is the language's own, and the build context is the script's own
    # directory (resolved via $(dirname "$0"), not the caller's CWD)
    echo "log: $(cat "$DOCKER_MOCK_LOG")"
    run grep -Fxq "docker build --no-cache -t ondewo-${lang}-proto-compiler:latest $REPO_ROOT/$lang" "$DOCKER_MOCK_LOG"
    [ "$status" -eq 0 ]
    # exactly one image built per wrapper
    [ "$(grep -c '^docker build' "$DOCKER_MOCK_LOG")" -eq 1 ]
  done
  [ "$checked" -ge 11 ]
}

@test "orch-1: every language build.sh propagates a docker build failure" {
  local lang checked=0
  for lang in $(lang_targets); do
    checked=$((checked + 1))
    : > "$DOCKER_MOCK_LOG"
    export FAIL_BUILD_MATCH="ondewo-${lang}-proto-compiler"
    run sh "$REPO_ROOT/$lang/build.sh"
    echo "$lang exited $status: $output"
    [ "$status" -ne 0 ]
    # the success banner must not be reached
    [[ "$output" != *"✅"* ]]
    [[ "$output" != *"Done .proto to grpc client stubs compilation"* ]]
  done
  unset FAIL_BUILD_MATCH
  [ "$checked" -ge 11 ]
}

# ---------------------------------------------------------------------------
# build-all.sh
# ---------------------------------------------------------------------------

@test "orch-2: build-all.sh fails when any single image build fails" {
  FAIL_BUILD_MATCH="ondewo-js-proto-compiler" run bash "$REPO_ROOT/build-all.sh"
  [ "$status" -ne 0 ]
  # must NOT reach the final all-images-built success banner
  [[ "$output" != *"Building all ondewo-proto-compilers docker images."* ]]
}

@test "orch-2: build-all.sh builds every language image, in its documented order" {
  run bash "$REPO_ROOT/build-all.sh"
  echo "$output"
  [ "$status" -eq 0 ]

  local expected built on_disk
  expected=$(build_all_languages)
  built=$(built_languages)
  on_disk=$(lang_targets)
  echo "expected: $(echo "$expected" | tr '\n' ' ')"
  echo "built:    $(echo "$built" | tr '\n' ' ')"

  # every target on disk is in the loop, and the loop is exactly what ran
  [ "$(echo "$on_disk" | grep -c .)" -ge 11 ]
  [ "$(echo "$expected" | sort)" = "$on_disk" ]
  [ "$built" = "$expected" ]
  # no image built twice
  [ "$(echo "$built" | sort -u | grep -c .)" -eq "$(echo "$built" | grep -c .)" ]
}

@test "orch-2: a failure in any language aborts build-all.sh before the later ones" {
  local lang built last l checked=0
  for lang in $(lang_targets); do
    checked=$((checked + 1))
    : > "$DOCKER_MOCK_LOG"
    export FAIL_BUILD_MATCH="ondewo-${lang}-proto-compiler"
    run bash "$REPO_ROOT/build-all.sh"
    echo "$lang: exit $status"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"${lang} build FAILED"* ]]
    [[ "$output" != *"Building all ondewo-proto-compilers docker images."* ]]
    # the failing language is the LAST docker build attempted: the loop aborts
    # instead of ploughing on through the remaining targets
    built=$(built_languages)
    last=""
    for l in $built; do last="$l"; done
    echo "built: $(echo "$built" | tr '\n' ' ')"
    [ "$last" = "$lang" ]
  done
  unset FAIL_BUILD_MATCH
  [ "$checked" -ge 11 ]
}

@test "orch-2: build-all.sh fails loudly when a language directory is missing" {
  # The guard is what turns a half-wired new target into a build break instead
  # of a silently skipped image.
  local lang
  cp "$REPO_ROOT/build-all.sh" "$SANDBOX/build-all.sh"
  for lang in $(build_all_languages); do
    if [ "$lang" = "php" ]; then continue; fi
    mkdir -p "$SANDBOX/$lang"
    printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/$lang/build.sh"
  done

  run bash "$SANDBOX/build-all.sh"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing dir php"* ]]
  [[ "$output" != *"Building all ondewo-proto-compilers docker images."* ]]
}
