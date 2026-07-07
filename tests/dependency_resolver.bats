#!/usr/bin/env bats
# Tests for js/image-data/dependecy-resolver.sh — pure shell, no Docker/protoc.
# Source the file and exercise echoProtoDependencies against tiny proto trees.
# Covers recursive resolution, google/protobuf exclusion, loud failure on an
# unresolvable import (js-3), and correct path handling after the IFS fix (js-6).

load 'helpers/setup'

setup() {
  common_setup
  source "$REPO_ROOT/js/image-data/dependecy-resolver.sh"
}
teardown() { common_teardown; }

@test "resolves a transitive import chain a -> b -> c" {
  printf 'import "b.proto";\n' > "$SANDBOX/a.proto"
  printf 'import "c.proto";\n' > "$SANDBOX/b.proto"
  printf 'message C {}\n'       > "$SANDBOX/c.proto"

  run echoProtoDependencies "$SANDBOX" "$SANDBOX/a.proto"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a.proto"* ]]
  [[ "$output" == *"b.proto"* ]]
  [[ "$output" == *"c.proto"* ]]
}

@test "excludes google/protobuf imports without failing" {
  printf 'import "google/protobuf/timestamp.proto";\n' > "$SANDBOX/a.proto"
  run echoProtoDependencies "$SANDBOX" "$SANDBOX/a.proto"
  [ "$status" -eq 0 ]
  [[ "$output" != *"timestamp.proto"* ]]
}

@test "js-3: an unresolvable import fails loudly (exit 1)" {
  printf 'import "does-not-exist.proto";\n' > "$SANDBOX/a.proto"
  run echoProtoDependencies "$SANDBOX" "$SANDBOX/a.proto"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to resolve"* ]]
}

@test "js-6: a relative import path resolves to the correct file (IFS not mangled)" {
  mkdir -p "$SANDBOX/sub"
  printf 'import "sub/dep.proto";\n' > "$SANDBOX/a.proto"
  printf 'message Dep {}\n'          > "$SANDBOX/sub/dep.proto"
  run echoProtoDependencies "$SANDBOX" "$SANDBOX/a.proto"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sub/dep.proto"* ]]
}
