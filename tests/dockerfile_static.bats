#!/usr/bin/env bats
# Cheap, no-build static checks over the Dockerfiles + Makefile (a hadolint
# substitute). Guards the Dockerfile-hygiene fixes and the Node version split.

load 'helpers/setup'

setup() { common_setup; }
teardown() { common_teardown; }

@test "mk-6: node Dockerfiles pin the same NODE_VERSION as the Makefile" {
  ver=$(grep -E '^NODE_VERSION=' "$REPO_ROOT/Makefile" | head -1 | cut -d= -f2)
  [ -n "$ver" ]
  for df in angular js nodejs typescript; do
    run grep -Fxq "ARG NODE_VERSION=$ver" "$REPO_ROOT/$df/Dockerfile"
    [ "$status" -eq 0 ]
  done
}

@test "py-1: python Dockerfile uses exec-form ENTRYPOINT" {
  run grep -Eq '^ENTRYPOINT \[' "$REPO_ROOT/python/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "no shell-form ENTRYPOINT in any Dockerfile" {
  for df in angular js nodejs typescript python; do
    # every ENTRYPOINT line must be the exec-form JSON array
    run bash -c "grep -E '^ENTRYPOINT' '$REPO_ROOT/$df/Dockerfile' | grep -vE '^ENTRYPOINT \['"
    [ -z "$output" ]
  done
}

@test "js-1: js Dockerfile has no invalid 'npm install -g -D ... --yes'" {
  run grep -Eq 'npm install -g -D|--yes' "$REPO_ROOT/js/Dockerfile"
  [ "$status" -ne 0 ]
}

@test "js-2: no 'ADD image-data/*' wildcard that flattens default-lib-files" {
  run grep -Eq '^ADD image-data/\* ' "$REPO_ROOT/js/Dockerfile"
  [ "$status" -ne 0 ]
}

@test "image-data is copied with COPY directory form in the node images" {
  for df in angular js nodejs typescript; do
    run grep -Eq '^COPY image-data/ /image-data/' "$REPO_ROOT/$df/Dockerfile"
    [ "$status" -eq 0 ]
  done
}
