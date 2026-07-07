#!/usr/bin/env bats
# Regression guard for the compile-proto-2-stubs.sh scripts.
# - nodejs/typescript: the optional "dependency" protoc pass must NOT run (and
#   abort the build) when the deps file is empty — which happens whenever the
#   compiled protos have no google/ imports. A non-empty deps file must still
#   trigger dependency compilation.
# - js: the protoc invocation is a direct call (no eval) and still compiles the
#   resolved proto set.
# - angular/typescript: the no-protos guard counts real *.proto files via find
#   instead of grepping tree output (which also matched ".proto" substrings in
#   directory names).

load 'helpers/setup'

setup() {
  common_setup
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  SRC="$SANDBOX/src"; mkdir -p "$SRC"
  printf 'message A {}\n' > "$SRC/a.proto"
  DEPS="$SANDBOX/proto-deps.txt"
  OUT="$SANDBOX/out"
}
teardown() { common_teardown; }

# run_stub <lang>
run_stub() {
  run bash "$REPO_ROOT/$1/image-data/compile-proto-2-stubs.sh" "$OUT" "$SRC" "$SRC" "$DEPS"
}

@test "nodejs stub: empty deps file does not abort the build" {
  printf '\n' > "$DEPS"           # whitespace-only, as produced for imports-free protos
  run_stub nodejs
  [ "$status" -eq 0 ]
}

@test "nodejs stub: non-empty deps file triggers dependency compilation" {
  printf 'google/protobuf/timestamp.proto\n' > "$DEPS"
  run_stub nodejs
  [ "$status" -eq 0 ]
  run grep -Fq "timestamp.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "typescript stub: empty deps file does not abort the build" {
  printf '   \n' > "$DEPS"
  run_stub typescript
  [ "$status" -eq 0 ]
}

@test "typescript stub: non-empty deps file triggers dependency compilation" {
  printf 'google/protobuf/timestamp.proto\n' > "$DEPS"
  run_stub typescript
  [ "$status" -eq 0 ]
  run grep -Fq "timestamp.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "js stub: compiles the resolved proto set via direct protoc invocation" {
  run bash "$REPO_ROOT/js/image-data/compile-proto-2-stubs.sh" "$OUT" "$SRC" "$SRC"
  [ "$status" -eq 0 ]
  run grep -Fq "a.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "angular stub: compiles protos found in the source dir" {
  run bash "$REPO_ROOT/angular/image-data/compile-proto-2-stubs.sh" "$OUT" "$SRC" "$SRC"
  [ "$status" -eq 0 ]
  run grep -Fq "a.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "angular stub: no-protos guard is not fooled by '.proto' in a directory name" {
  EMPTY="$SANDBOX/dir.protos"; mkdir -p "$EMPTY"
  run bash "$REPO_ROOT/angular/image-data/compile-proto-2-stubs.sh" "$OUT" "$EMPTY" "$EMPTY"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No proto files were found"* ]]
}

@test "typescript stub: no-protos guard is not fooled by '.proto' in a directory name" {
  EMPTY="$SANDBOX/dir.protos"; mkdir -p "$EMPTY"
  run bash "$REPO_ROOT/typescript/image-data/compile-proto-2-stubs.sh" "$OUT" "$EMPTY" "$EMPTY" "$DEPS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No proto files were found"* ]]
}
