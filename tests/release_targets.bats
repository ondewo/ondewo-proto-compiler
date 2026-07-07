#!/usr/bin/env bats
# Tests for the root Makefile release version-bump targets, run against a
# sandbox copy of the Makefile + Dockerfiles + package.json files with a
# PATH-mock git (real sed/jq). Guards the BSD/macOS-portable `sed -i.bak`
# rewrite: versions must land in every file and no *.bak may be left behind.

load 'helpers/setup'

PKG_FILES="angular/example/package.json angular/image-data/package.json \
js/image-data/default-lib-files/package.json nodejs/example/package.json \
nodejs/image-data/package.json typescript/example/package.json \
typescript/image-data/package.json"

setup() {
  common_setup
  export GIT_MOCK_LOG="$SANDBOX/git.log"
  REPO="$SANDBOX/repo"
  mkdir -p "$REPO"
  cp "$REPO_ROOT/Makefile" "$REPO/Makefile"
  for lang in angular js nodejs typescript python; do
    mkdir -p "$REPO/$lang"
    cp "$REPO_ROOT/$lang/Dockerfile" "$REPO/$lang/Dockerfile"
  done
  cp "$REPO_ROOT/Dockerfile.utils" "$REPO/Dockerfile.utils"
  for f in $PKG_FILES; do
    mkdir -p "$REPO/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$REPO/$f"
  done
}
teardown() { common_teardown; }

@test "release_version_update_in_dockerfiles rewrites every ARG version" {
  run make -C "$REPO" release_version_update_in_dockerfiles \
    PYTHON_VERSION=9.9 NODE_VERSION=99.99.0 PROTOC_VERSION=88.0 GRPC_WEB_VERSION=7.7.7
  [ "$status" -eq 0 ]
  for df in angular js nodejs typescript; do
    run grep -Fxq "ARG NODE_VERSION=99.99.0" "$REPO/$df/Dockerfile"
    [ "$status" -eq 0 ]
    run grep -Fxq "ARG PROTOC_VERSION=88.0" "$REPO/$df/Dockerfile"
    [ "$status" -eq 0 ]
  done
  run grep -Fxq "ARG PYTHON_VERSION=9.9" "$REPO/python/Dockerfile"
  [ "$status" -eq 0 ]
  run grep -Fxq "ARG PYTHON_VERSION=9.9" "$REPO/Dockerfile.utils"
  [ "$status" -eq 0 ]
}

@test "dockerfile version bump leaves no sed .bak backups behind (portable -i.bak)" {
  run make -C "$REPO" release_version_update_in_dockerfiles NODE_VERSION=99.99.0
  [ "$status" -eq 0 ]
  run bash -c "find '$REPO' -name '*.bak' | grep -c ."
  [ "$output" = "0" ]
}

@test "release_version_update_in_packages_json_files bumps every listed package.json" {
  run make -C "$REPO" release_version_update_in_packages_json_files \
    ONDEWO_PROTO_COMPILER_VERSION=6.1.2
  [ "$status" -eq 0 ]
  for f in $PKG_FILES; do
    run jq -r .version "$REPO/$f"
    [ "$output" = "6.1.2" ]
  done
  # the jq staging temp file must not survive
  [ ! -f "$REPO/tmp.json" ]
}

@test "version bump targets commit+push via git when there are staged changes" {
  run make -C "$REPO" release_version_update_in_dockerfiles NODE_VERSION=99.99.0
  [ "$status" -eq 0 ]
  run grep -Eq '^git commit' "$GIT_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Eq '^git push' "$GIT_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "version bump targets skip commit when nothing is staged (GIT_DIFF_RC=0)" {
  GIT_DIFF_RC=0 run make -C "$REPO" release_version_update_in_dockerfiles NODE_VERSION=99.99.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"[NOOP]"* ]]
  run grep -Eq '^git commit' "$GIT_MOCK_LOG"
  [ "$status" -ne 0 ]
}
