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
  # Every language listed in the Makefile's DOCKERFILES must be present: the target now fails
  # loudly on a missing Dockerfile rather than letting perl warn and `git add` error out.
  for lang in angular js nodejs typescript python php go rust cpp java csharp; do
    mkdir -p "$REPO/$lang"
    cp "$REPO_ROOT/$lang/Dockerfile" "$REPO/$lang/Dockerfile"
  done
  cp "$REPO_ROOT/Dockerfile.utils" "$REPO/Dockerfile.utils"
  for f in $PKG_FILES; do
    mkdir -p "$REPO/$(dirname "$f")"
    cp "$REPO_ROOT/$f" "$REPO/$f"
  done
  # CURRENT_RELEASE_NOTES / check_release_notes read RELEASE.md out of the make CWD.
  cp "$REPO_ROOT/RELEASE.md" "$REPO/RELEASE.md"
}

# Write a throwaway RELEASE.md into the sandbox, newest section first like the real one.
write_release_md() {
  printf '%s\n' "$@" > "$REPO/RELEASE.md"
}

# The sliced notes `make TEST` prints, without its three credential diagnostic lines.
sliced_notes() {
  make -C "$REPO" TEST ONDEWO_PROTO_COMPILER_VERSION="$1" 2>/dev/null | tail -n +4
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

########################################################
# Release pre-flight guards
#
# Everything from the first version-bump target onwards is public and not cleanly
# undoable: three commits pushed to the current branch, a pushed release branch, a
# pushed tag. The token used to be validated only inside the utils image - i.e. after
# all of that - and nothing checked that RELEASE.md actually carries notes for the
# version being cut, so `gh release create -n ""` would publish an empty body.
########################################################

@test "check_release_notes passes for a version RELEASE.md documents" {
  run make -C "$REPO" check_release_notes ONDEWO_PROTO_COMPILER_VERSION=5.15.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SUCCESS]"* ]]
}

@test "check_release_notes fails for a version RELEASE.md does not document" {
  run make -C "$REPO" check_release_notes ONDEWO_PROTO_COMPILER_VERSION=99.98.97
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty body"* ]]
}

@test "check_release_notes fails on a version heading with no notes under it" {
  write_release_md '# Release History' '' '*****************' '' \
    '## Release ONDEWO Proto Compiler 9.9.9' '' '*****************'
  run make -C "$REPO" check_release_notes ONDEWO_PROTO_COMPILER_VERSION=9.9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty body"* ]]
}

@test "the release notes slice is not cut short by a **bold** span inside the notes" {
  # Regression: the flip-flop terminator used to be /\*\*/, which ends the range on the
  # first bold marker rather than on the ***** separator - the real 5.15.0 section sliced
  # down to 3 of its 8 lines that way, so that GitHub release shipped almost no notes.
  write_release_md '# Release History' '' '*****************' '' \
    '## Release ONDEWO Proto Compiler 9.9.9' '' '### Improvements' '' \
    '* first bullet naming **eleven** targets' \
    '* second bullet that must survive' '' '*****************' '' \
    '## Release ONDEWO Proto Compiler 9.9.8' '' '* notes of the previous release' '' \
    '*****************'
  run sliced_notes 9.9.9
  [ "$status" -eq 0 ]
  [[ "$output" == *"first bullet naming"* ]]
  [[ "$output" == *"second bullet that must survive"* ]]
  # ...and it must still stop at the separator instead of swallowing the older section
  [[ "$output" != *"notes of the previous release"* ]]
}

@test "the release notes slice does not open on a newer version that extends the current one" {
  # RELEASE.md is newest-first and the version is interpolated into a regex, so an
  # unanchored opener lets 1.1.1 match the 1.1.10 heading it meets first.
  write_release_md '# Release History' '' '*****************' '' \
    '## Release ONDEWO Proto Compiler 1.1.10' '' '* notes of the newer release' '' \
    '*****************' '' \
    '## Release ONDEWO Proto Compiler 1.1.1' '' '* notes of the older release' '' \
    '*****************'
  run sliced_notes 1.1.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"notes of the older release"* ]]
  [[ "$output" != *"notes of the newer release"* ]]
}

@test "check_release_credentials rejects an unset and a placeholder GITHUB_GH_TOKEN" {
  run make -C "$REPO" check_release_credentials GITHUB_GH_TOKEN=ENTER_YOUR_TOKEN_HERE
  [ "$status" -ne 0 ]
  [[ "$output" == *"GITHUB_GH_TOKEN is not set"* ]]
  run make -C "$REPO" check_release_credentials GITHUB_GH_TOKEN=
  [ "$status" -ne 0 ]
  run make -C "$REPO" check_release_credentials GITHUB_GH_TOKEN=gh_a_real_looking_token
  [ "$status" -eq 0 ]
}

@test "release aborts on a missing token without pushing anything" {
  run make -C "$REPO" release GITHUB_GH_TOKEN=ENTER_YOUR_TOKEN_HERE
  [ "$status" -ne 0 ]
  [[ "$output" == *"GITHUB_GH_TOKEN is not set"* ]]
  # nothing irreversible may have happened: no commit, no push, no branch, no tag
  if [ -f "$GIT_MOCK_LOG" ]; then
    run grep -Eq '^git (push|commit|tag|checkout)' "$GIT_MOCK_LOG"
    [ "$status" -ne 0 ]
  fi
}

@test "release aborts on missing release notes without pushing anything" {
  write_release_md '# Release History' '' '*****************'
  run make -C "$REPO" release GITHUB_GH_TOKEN=gh_a_real_looking_token
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty body"* ]]
  if [ -f "$GIT_MOCK_LOG" ]; then
    run grep -Eq '^git (push|commit|tag|checkout)' "$GIT_MOCK_LOG"
    [ "$status" -ne 0 ]
  fi
}

@test "release runs all three pre-flight guards before the first push" {
  run make -C "$REPO" -n release GITHUB_GH_TOKEN=gh_a_real_looking_token
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$SANDBOX/dryrun.txt"
  credentials="$(grep -n 'GITHUB_GH_TOKEN is not set' "$SANDBOX/dryrun.txt" | head -1 | cut -d: -f1)"
  notes="$(grep -n 'empty body' "$SANDBOX/dryrun.txt" | head -1 | cut -d: -f1)"
  spc="$(grep -n 'Test 2: Tag' "$SANDBOX/dryrun.txt" | head -1 | cut -d: -f1)"
  push="$(grep -n 'git push' "$SANDBOX/dryrun.txt" | head -1 | cut -d: -f1)"
  [ -n "$credentials" ] && [ -n "$notes" ] && [ -n "$spc" ] && [ -n "$push" ]
  [ "$credentials" -lt "$push" ]
  [ "$notes" -lt "$push" ]
  [ "$spc" -lt "$push" ]
}

@test "login_to_gh and build_gh_release carry the guards for the in-image push_to_gh path" {
  # push_to_gh runs inside the utils image, where the host-side pre-flight has no reach.
  run make -C "$REPO" -n push_to_gh GITHUB_GH_TOKEN=ENTER_YOUR_TOKEN_HERE
  [ "$status" -eq 0 ]
  [[ "$output" == *"GITHUB_GH_TOKEN is not set"* ]]
  [[ "$output" == *"empty body"* ]]
}
