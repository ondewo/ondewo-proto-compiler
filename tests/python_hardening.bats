#!/usr/bin/env bats
# Hardening tests for the python target (python/Makefile), covering the bug
# classes the six newer targets were fixed for in 5.15.0:
#
#   * `find -path '*.proto'` without `-type f`, so a DIRECTORY named *.proto is
#     handed to protoc - or, on its own, satisfies the "no protos" guard.
#   * the entry list consumed as `for f in $files`, which word-splits a path
#     containing a space and GLOB-expands one containing [ ] * ? - compiling the
#     wrong set of files, skipping the real proto, and still exiting 0.
#   * `run` mounting an unset/absent host directory: docker creates a missing
#     bind-mount source as an empty ROOT-owned directory, and an EMPTY
#     EXTRA_PROTO_DIR expanded to `-v $(pwd)/:/...../protos/`, mounting the whole
#     working tree over the image's proto root.
#
# Everything runs against PATH-mock `python` / `docker`; no image is needed.

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

# Number of protoc invocations recorded by the mock (`grep -c .`, never `wc -l`:
# BSD wc pads its output with spaces).
protoc_calls() {
  grep -c . "$PY_MOCK_LOG" 2>/dev/null || true
}

# The argument protoc was given, i.e. everything after the last --grpc_python_out flag.
compiled_paths() {
  sed 's|.*--grpc_python_out=[^ ]* ||' "$PY_MOCK_LOG"
}

# A `run` target sandbox: the Makefile copied out of the repo so the mounts,
# which are built as ${shell pwd}/${VAR}, resolve inside $SANDBOX.
setup_run_sandbox() {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  mkdir -p "$SANDBOX/mk/protos"
  cp "$REPO_ROOT/python/Makefile" "$SANDBOX/mk/Makefile"
  cd "$SANDBOX/mk"
}

#####################################################################################
# generate_protos: the entry set
#####################################################################################

@test "python guard: a DIRECTORY named *.proto is not handed to protoc" {
  mkdir -p "$PROTO_DIR/stale.proto"
  printf 'message A {}\n' > "$PROTO_DIR/a.proto"
  gen
  [ "$status" -eq 0 ]
  run protoc_calls
  [ "$output" -eq 1 ]
  run grep -F "stale.proto" "$PY_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "python guard: a DIRECTORY named *.proto does not satisfy the no-protos guard" {
  mkdir -p "$PROTO_DIR/stale.proto"
  gen
  [ "$status" -ne 0 ]
  [[ "$output" == *"no .proto files found"* ]]
  [ ! -s "$PY_MOCK_LOG" ]
}

@test "python guard: a DIRECTORY named *.proto under the target sub-dir is skipped too" {
  mkdir -p "$PROTO_DIR/ondewo/stale.proto"
  printf 'message A {}\n' > "$PROTO_DIR/ondewo/a.proto"
  INTERNAL_TARGET_PROTO_DIR="ondewo" gen
  [ "$status" -eq 0 ]
  run protoc_calls
  [ "$output" -eq 1 ]
  run grep -F "stale.proto" "$PY_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "python paths: a proto whose name contains a space is compiled as ONE argument" {
  printf 'message A {}\n' > "$PROTO_DIR/my service.proto"
  gen
  [ "$status" -eq 0 ]
  run protoc_calls
  [ "$output" -eq 1 ]
  run compiled_paths
  [ "$output" = "$PROTO_DIR/my service.proto" ]
}

@test "python paths: a proto whose name contains glob metacharacters is not expanded away" {
  # An unquoted $files expands '[a].proto' against the filesystem: the real file is
  # silently dropped and a.proto is compiled twice, with a zero exit code.
  printf 'message A {}\n'  > "$PROTO_DIR/a.proto"
  printf 'message BR {}\n' > "$PROTO_DIR/[a].proto"
  gen
  [ "$status" -eq 0 ]
  run protoc_calls
  [ "$output" -eq 2 ]
  run grep -F -- "$PROTO_DIR/[a].proto" "$PY_MOCK_LOG"
  [ "$status" -eq 0 ]
  # ... and a.proto exactly once, not twice
  run grep -c -F -- "$PROTO_DIR/a.proto" "$PY_MOCK_LOG"
  [ "$output" -eq 1 ]
}

@test "python paths: a proto whose name contains a newline aborts instead of compiling fragments" {
  nl='
'
  printf 'message A {}\n' > "$PROTO_DIR/we${nl}ird.proto"
  gen
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a readable .proto file"* ]]
  # the two bogus fragments must never reach protoc
  [ ! -s "$PY_MOCK_LOG" ]
}

#####################################################################################
# generate_protos: failure propagation out of the `find | while read` pipeline
#####################################################################################

@test "python failure: the first protoc failure aborts the loop, nothing else is compiled" {
  printf 'message A {}\n' > "$PROTO_DIR/a.proto"
  printf 'message B {}\n' > "$PROTO_DIR/b.proto"
  printf 'message C {}\n' > "$PROTO_DIR/c.proto"
  PY_FAIL_MATCH=".proto" gen
  [ "$status" -ne 0 ]
  run protoc_calls
  [ "$output" -eq 1 ]
}

@test "python failure: a protoc exit code propagates out of the pipeline" {
  printf 'message A {}\n' > "$PROTO_DIR/a.proto"
  PY_FAIL_MATCH="a.proto" PY_FAIL_RC=3 gen
  [ "$status" -ne 0 ]
}

#####################################################################################
# run: mounts and output ownership
#####################################################################################

@test "python make: an unset EXTRA_PROTO_DIR mounts nothing extra (never the whole CWD)" {
  setup_run_sandbox
  printf 'message A {}\n' > "$SANDBOX/mk/protos/a.proto"
  run make run
  [ "$status" -eq 0 ]
  # exactly two bind mounts: the output dir and the proto dir
  run bash -c "tr ' ' '\n' < '$DOCKER_MOCK_LOG' | grep -c '^-v\$' || true"
  [ "$output" -eq 2 ]
  # the working directory itself is never mounted over the image's proto root
  run grep -F -- "-v $SANDBOX/mk/:" "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
  run grep -F -- ":/home/ondewo/ondewo-proto-compiler/protos/ " "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "python make: an explicitly empty EXTRA_PROTO_DIR= mounts nothing extra either" {
  setup_run_sandbox
  run make run EXTRA_PROTO_DIR=
  [ "$status" -eq 0 ]
  run bash -c "tr ' ' '\n' < '$DOCKER_MOCK_LOG' | grep -c '^-v\$' || true"
  [ "$output" -eq 2 ]
  run grep -F -- "-v $SANDBOX/mk/:" "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "python make: a set EXTRA_PROTO_DIR is mounted under its basename, trailing slash normalised" {
  setup_run_sandbox
  mkdir -p "$SANDBOX/mk/api/google"
  run make run EXTRA_PROTO_DIR=api/google/
  [ "$status" -eq 0 ]
  run grep -F -- "-v $SANDBOX/mk/api/google/:/home/ondewo/ondewo-proto-compiler/protos/google" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "python make: a non-existent PROTO_DIR fails loudly and creates no root-owned mount point" {
  setup_run_sandbox
  run make run PROTO_DIR=no-such-protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"PROTO_DIR='no-such-protos' is not a directory"* ]]
  [ ! -e "$SANDBOX/mk/no-such-protos" ]
  [ ! -f "$DOCKER_MOCK_LOG" ]
}

@test "python make: a non-existent EXTRA_PROTO_DIR fails loudly before docker runs" {
  setup_run_sandbox
  run make run EXTRA_PROTO_DIR=no-such-google
  [ "$status" -ne 0 ]
  [[ "$output" == *"EXTRA_PROTO_DIR='no-such-google' is not a directory"* ]]
  [ ! -e "$SANDBOX/mk/no-such-google" ]
  [ ! -f "$DOCKER_MOCK_LOG" ]
}

@test "python make: an empty PROTO_DIR or OUTPUT_DIR is rejected, not mounted as the CWD" {
  setup_run_sandbox
  run make run PROTO_DIR=
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not be empty"* ]]
  [ ! -f "$DOCKER_MOCK_LOG" ]

  run make run OUTPUT_DIR=
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not be empty"* ]]
  [ ! -f "$DOCKER_MOCK_LOG" ]
}

@test "python make: the output dir is pre-created by the caller and the container runs as that user" {
  setup_run_sandbox
  [ ! -d "$SANDBOX/mk/output" ]
  run make run
  [ "$status" -eq 0 ]
  # created by make, so it is caller-owned; docker would have created it as root
  [ -d "$SANDBOX/mk/output" ]
  [ -O "$SANDBOX/mk/output" ]
  run grep -F -- "--user $(id -u):$(id -g)" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -F -- "-v $SANDBOX/mk/output:/home/ondewo/ondewo-proto-compiler/output" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  # no -it: it breaks every non-interactive caller
  run bash -c "tr ' ' '\n' < '$DOCKER_MOCK_LOG' | grep -c '^-it\$' || true"
  [ "$output" -eq 0 ]
}
