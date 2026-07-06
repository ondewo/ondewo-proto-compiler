#!/usr/bin/env bats
# Tests for python/Makefile `generate_protos` with a PATH-mock python (no Docker,
# no real grpc_tools). Covers mk-1 (protoc failure aborts), mk-2 (target dir is
# anchored so siblings are excluded), mk-3 (empty match fails loudly), and mk-8
# (no dangling empty INCLUDE_DIR in the -I flag).

load 'helpers/setup'

setup() {
  common_setup
  export PY_MOCK_LOG="$SANDBOX/python.log"
  PROTO_DIR="$SANDBOX/protos"
  OUT_DIR="$SANDBOX/out"
  mkdir -p "$PROTO_DIR" "$OUT_DIR"
}
teardown() { common_teardown; }

gen() {
  run make -C "$REPO_ROOT/python" -f Makefile generate_protos \
    INTERNAL_PROTO_DIR="$PROTO_DIR" INTERNAL_OUTPUT_DIR="$OUT_DIR"
}

@test "mk-3: no .proto files fails loudly and never calls protoc" {
  gen
  [ "$status" -ne 0 ]
  [[ "$output" == *"no .proto files found"* ]]
  [ ! -s "$PY_MOCK_LOG" ]
}

@test "compiles every proto when protoc succeeds" {
  printf 'message A {}\n' > "$PROTO_DIR/a.proto"
  printf 'message B {}\n' > "$PROTO_DIR/b.proto"
  gen
  [ "$status" -eq 0 ]
  run grep -c 'grpc_tools.protoc' "$PY_MOCK_LOG"
  [ "$output" -eq 2 ]
}

@test "mk-1: a protoc failure aborts the target with a non-zero exit" {
  printf 'message A {}\n' > "$PROTO_DIR/a.proto"
  printf 'message B {}\n' > "$PROTO_DIR/b.proto"
  PY_FAIL_MATCH="a.proto" gen
  [ "$status" -ne 0 ]
}

@test "mk-2: INTERNAL_TARGET_PROTO_DIR is anchored (sibling dirs excluded)" {
  mkdir -p "$PROTO_DIR/foo" "$PROTO_DIR/foobar"
  printf 'message F {}\n'  > "$PROTO_DIR/foo/a.proto"
  printf 'message FB {}\n' > "$PROTO_DIR/foobar/b.proto"
  INTERNAL_TARGET_PROTO_DIR="foo" gen
  [ "$status" -eq 0 ]
  run grep -F "foo/a.proto" "$PY_MOCK_LOG"
  [ "$status" -eq 0 ]
  # the sibling 'foobar' must NOT be swept in by the anchored glob
  run grep -F "foobar/b.proto" "$PY_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "mk-8: -I include path has no dangling empty INCLUDE_DIR segment" {
  printf 'message A {}\n' > "$PROTO_DIR/a.proto"
  gen
  [ "$status" -eq 0 ]
  # correct: '-I <protodir> '  (a trailing slash would mean the old empty INCLUDE_DIR bug)
  run grep -F -- "-I $PROTO_DIR " "$PY_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -F -- "-I $PROTO_DIR/ " "$PY_MOCK_LOG"
  [ "$status" -ne 0 ]
}
