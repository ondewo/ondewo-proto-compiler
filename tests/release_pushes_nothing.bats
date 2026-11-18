#!/usr/bin/env bats
# Decision D12 (OND236-120): the release targets work on the CURRENT branch and push nothing.
# `make release` used to push three commits to the current branch, a release branch and a tag,
# publish the GitHub release, and then clone all 77 client repos and push a submodule bump to
# their default branch (master). Publishing is a separate, explicit step now, and every client
# bump is committed on CLIENT_BRANCH in a local clone that is left for review.

load 'helpers/setup'

setup() {
  common_setup
  export GIT_MOCK_LOG="$SANDBOX/git.log"
}
teardown() { common_teardown; }

# The recipe lines of every release target of the Makefile, as "<target>: <line>".
release_recipes() {
  awk '
    /^[A-Za-z_][A-Za-z0-9_-]*:/ {
      target = $0; sub(/:.*/, "", target)
      inrel = (target ~ /^(release|create_release|ondewo_release|run_release)/)
      next
    }
    /^\t/ && inrel { print target ": " $0 }
    /^[^\t]/ { inrel = 0 }
  ' "$REPO_ROOT/Makefile"
}

@test "D12: no release target of the Makefile contains 'git push'" {
  local recipes
  recipes="$(release_recipes)"
  # the extraction itself must see the release targets, or this test passes vacuously
  [[ "$recipes" == *"release_version_update_in_dockerfiles:"* ]]
  [[ "$recipes" == *"create_release_tag:"* ]]
  run sh -c "printf '%s\n' \"\$1\" | grep -F 'git push'" _ "$recipes"
  echo "$output"
  [ "$status" -ne 0 ]
}

@test "D12: the client bump script contains no 'git push'" {
  run sh -c "grep -v '^[[:space:]]*#' '$REPO_ROOT/update_proto_compiler_dependency.sh' | grep -F 'git push'"
  echo "$output"
  [ "$status" -ne 0 ]
}

@test "D12: make release neither creates a release branch, publishes, nor bumps the clients" {
  run make -C "$REPO_ROOT" -n release GITHUB_GH_TOKEN=gh_a_real_looking_token
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"git push"* ]]
  [[ "$output" != *"git checkout -b"* ]]
  [[ "$output" != *"gh release create"* ]]
  [[ "$output" != *"release_to_github_via_docker_image"* ]]
  [[ "$output" != *"update_proto_compiler_dependency.sh"* ]]
}
