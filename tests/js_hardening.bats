#!/usr/bin/env bats
# Hardening regressions for the js target, closing the gap to the bug classes that
# were fixed in the six newer targets (php/go/rust/cpp/java/csharp) in 5.15.0.
#
# Three defects, all of them "a path that is not a regular file is treated as one":
#   1. js/image-data/dependecy-resolver.sh had no post-fixup readability check, so a
#      proto whose FILENAME contains a newline - which `while IFS= read -r` splits
#      into two fragments, neither of which is a file - silently dropped the real
#      proto, handed protoc the bogus tail fragment and still EXITED 0.
#   2. compile-proto-2-stubs.sh's entry-set `find` had no `-type f`, so a DIRECTORY
#      named "*.proto" satisfied the "are there any protos?" guard.
#   3. the generated-stub tally used `find ... | wc -l` without `-type f`, counting a
#      DIRECTORY named "*.js" as a generated stub (and using the BSD-padded `wc -l`
#      rather than the repo's `| grep -c . || true` idiom).
#
# Everything here runs against the PATH-mock protoc - no Docker, no real toolchain.

load 'helpers/setup'

setup() {
  common_setup
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  SRC="$SANDBOX/src"
  OUT="$SANDBOX/out"
  mkdir -p "$SRC"
}
teardown() { common_teardown; }

run_js_stubs() {
  run bash "$REPO_ROOT/js/image-data/compile-proto-2-stubs.sh" "$OUT" "$SRC" "$SRC"
}

# ---------------------------------------------------------------------------
# 1. silent data loss: a proto whose filename contains a newline
# ---------------------------------------------------------------------------

@test "js stubs: a proto whose filename contains a newline aborts instead of compiling a mangled list" {
  # Before the resolver guard this printed "Found 3 .proto files", dropped the real
  # "we\nird.proto", compiled the bogus tail fragment "ird.proto" and exited 0 with a
  # library that was missing a service.
  printf 'syntax = "proto3";\nmessage A {}\n' > "$SRC/ok.proto"
  printf 'syntax = "proto3";\nmessage B {}\n' > "$SRC/$(printf 'we\nird')".proto

  run_js_stubs
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a readable .proto file"* ]]
  # the guard must `exit`, not `return`: that is the only thing the caller's
  # `if ! ALL_PROTO_FILES=$(echoProtoDependencies ...)` can observe
  [[ "$output" == *"Dependency resolution failed"* ]]
  # and nothing at all was compiled from the mangled list
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "js resolver: a list entry that is not a readable file after the root-prefix fixup exits 1" {
  # The fixup prepends the proto root to anything that is not already a file. When the
  # result is still not a file the list was mangled; continuing builds a nonsense path,
  # fails relativeToRoot and sed on stderr, and returns success anyway.
  source "$REPO_ROOT/js/image-data/dependecy-resolver.sh"
  run echoProtoDependencies "$SANDBOX" "$SANDBOX/no-such.proto"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a readable .proto file"* ]]
}

@test "js resolver: the guard does not fire for a well-formed nested proto tree" {
  # the readability check must not cost the resolver its normal behaviour
  mkdir -p "$SRC/sub"
  printf 'import "sub/dep.proto";\n' > "$SRC/a.proto"
  printf 'message Dep {}\n'          > "$SRC/sub/dep.proto"
  source "$REPO_ROOT/js/image-data/dependecy-resolver.sh"
  run echoProtoDependencies "$SRC" "$SRC/a.proto"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a.proto"* ]]
  [[ "$output" == *"sub/dep.proto"* ]]
  [[ "$output" != *"is not a readable"* ]]
}

# ---------------------------------------------------------------------------
# 2. a DIRECTORY named *.proto is not an input file
# ---------------------------------------------------------------------------

@test "js stubs: a DIRECTORY named *.proto is not handed to protoc as an input file" {
  printf 'syntax = "proto3";\nmessage A {}\n' > "$SRC/a.proto"
  mkdir -p "$SRC/bogus.proto"

  run_js_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 1 .proto files"* ]]
  grep -Fq "a.proto" "$PROTOC_MOCK_LOG"
  run grep -Fq "bogus.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "js stubs: a source tree whose only *.proto is a DIRECTORY reports 'no proto files'" {
  # the no-protos guard is the descriptive diagnosis; without -type f the directory
  # satisfied it and the failure surfaced much later, as an unresolvable path
  mkdir -p "$SRC/dir.proto"

  run_js_stubs
  [ "$status" -eq 1 ]
  [[ "$output" == *"No proto files were found"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

# ---------------------------------------------------------------------------
# 3. the generated-stub tally
# ---------------------------------------------------------------------------

@test "js stubs: the generated-stub count ignores a DIRECTORY named *.js" {
  # the stubs target dir is the copy of the mounted input volume, so a user directory
  # named "*.js" really does land next to the generated stubs
  printf 'syntax = "proto3";\nmessage A {}\n' > "$SRC/a.proto"
  mkdir -p "$OUT/vendor.js"

  run_js_stubs
  [ "$status" -eq 0 ]

  expected=$(find "$OUT" -type f -iname "*.js" | grep -c . || true)
  [ "$expected" -ge 1 ]
  # sanity: the directory is exactly what an untyped find would add on top
  untyped=$(find "$OUT" -iname "*.js" | grep -c . || true)
  [ "$untyped" -eq "$((expected + 1))" ]

  [[ "$output" == *"files generated by proto compilation: $expected"* ]]
}

@test "js stubs: counts with 'grep -c .', never with BSD-padded 'wc -l'" {
  # BSD/macOS wc pads its output with spaces; the repo standard is `| grep -c . || true`
  run bash -c "grep -nE 'wc[[:space:]]+-[a-zA-Z]*l' \"$REPO_ROOT\"/js/image-data/*.sh \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true"
  echo "$output"
  [ -z "$output" ]
}
