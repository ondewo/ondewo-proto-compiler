#!/usr/bin/env bats
# Hardening tests for the `typescript` target, closing the gap between it and the six
# targets hardened in 5.15.0 (php/go/rust/cpp/java/csharp). Everything here runs on the
# HOST: the container paths (/image-data, /input-volume, /output-volume) come from the env
# knobs the scripts expose and protoc/npm are PATH-mocked, so the whole pipeline runs
# without Docker.
#
# Two bug classes are pinned:
#
#   1. `find ... -iname "*.proto"` / `-iname "*.ts"` with no `-type f`. A DIRECTORY whose
#      name ends in .proto satisfies the no-protos guard, is then handed to protoc as a
#      positional input, and turns the script's own diagnostic into a protoc error; the
#      same omission lets a directory inflate the generated-stub count and put a dangling
#      folder export into the public-api barrel. js/ and the six new targets already carry
#      `-type f` at every one of these sites.
#
#   2. The proto-deps.txt pipeline, which used to parse import statements POSITIONALLY
#      (`cut -c 7-` / `cut -c 8-`) and then dedup them by grepping the line list with each
#      extracted token as an unanchored REGEX and deleting line numbers with sed. Any line
#      that was not exactly `import "path";` came out mangled, and a mangled token that
#      happened to be a substring of the word "import" (which is what a commented-out
#      import or an indented import produces) matched every other line in the file and had
#      them all deleted. The final `sort | uniq -u` then dropped - rather than collapsed -
#      whatever duplicates were left.

load 'helpers/setup'

setup() {
  common_setup
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  export NPM_MOCK_LOG="$SANDBOX/npm.log"

  IN="$SANDBOX/input"
  OUT="$SANDBOX/output"
  mkdir -p "$IN/protos/library" "$OUT"
  printf '{\n  "name": "@ondewo/test-client",\n  "version": "1.0.0"\n}\n' > "$IN/package.json"
}

teardown() { common_teardown; }

# Copy typescript/image-data into the sandbox and cd there (the orchestrator calls its
# siblings as ./x.sh and stages into $IMAGE_DATA_DIRECTORY), then point the container-path
# knobs at the sandbox. TEMP_SRC is the script's OWN default ($IMAGE_DATA_DIRECTORY/src)
# and is deliberately left unset in the environment, so that default is under test too.
stage() {
  cp -r "$REPO_ROOT/typescript/image-data" "$SANDBOX/image-data"
  cd "$SANDBOX/image-data"
  export IMAGE_DATA_DIRECTORY="$SANDBOX/image-data"
  export INPUT_VOLUME_FS="$IN"
  export OUTPUT_VOLUME_FS="$OUT"
  TEMP_SRC="$SANDBOX/image-data/src"
}

run_compile() { run bash ./compile-proto-2-typescript.sh "$@"; }

# The resolved dependency list the orchestrator hands to compile-proto-2-stubs.sh.
deps_file() { cat "$TEMP_SRC/proto-deps.txt"; }

# Number of non-blank lines in the resolved dependency list (grep -c, never wc: BSD pads).
deps_count() { grep -c '[^[:space:]]' "$TEMP_SRC/proto-deps.txt" || true; }

# Content + layout fingerprint of a tree, used to prove the mount is only ever read.
snapshot() { (cd "$1" && find . -print | sort && find . -type f -exec cksum {} + | sort); }

# A proto in the selected dir, written with an arbitrary import block.
write_proto() { # <name> <import lines...>
  local name=$1
  shift
  {
    printf 'syntax = "proto3";\npackage library;\n'
    printf '%s\n' "$@"
    printf 'message %s { string name = 1; }\n' "${name%.proto}"
  } > "$IN/protos/library/$name"
}

# ---------------------------------------------------------------------------
# 1. compile-proto-2-stubs.sh: find without -type f
# ---------------------------------------------------------------------------

@test "ts-stub: a DIRECTORY named *.proto does not satisfy the no-protos guard" {
  # Without `-type f` PROTO_FILES_CNT counts the directory, the guard passes, and the
  # directory is then handed to protoc as a positional input - so the run fails with
  # protoc's "Is a directory" instead of the script's own message.
  SRC="$SANDBOX/only-a-dir"
  mkdir -p "$SRC/not-a-file.proto"
  run bash "$REPO_ROOT/typescript/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/stubs" "$SRC" "$SRC" "$SANDBOX/none.txt"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No proto files were found"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "ts-stub: a DIRECTORY named *.proto is never handed to protoc as an input" {
  SRC="$SANDBOX/mixed"
  mkdir -p "$SRC/bogus.proto"
  printf 'syntax = "proto3";\nmessage A {}\n' > "$SRC/real.proto"
  run bash "$REPO_ROOT/typescript/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/stubs" "$SRC" "$SRC" "$SANDBOX/none.txt"
  echo "$output"
  [ "$status" -eq 0 ]
  # the count the script reports is the count of real protos, not of find hits
  # (captured before the greps below reuse $output)
  [[ "$output" == *"Found 1 .proto files"* ]]
  run grep -Fq "$SRC/real.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq "bogus.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "ts-stub: the generated-stub count counts files, not directories" {
  SRC="$SANDBOX/src"
  mkdir -p "$SRC"
  printf 'syntax = "proto3";\nmessage A {}\n' > "$SRC/a.proto"
  STUBS="$SANDBOX/stubs"
  # a user directory whose name ends in .ts, sitting in the stubs target dir
  mkdir -p "$STUBS/vendor.d.ts"
  run bash "$REPO_ROOT/typescript/image-data/compile-proto-2-stubs.sh" \
    "$STUBS" "$SRC" "$SRC" "$SANDBOX/none.txt"
  echo "$output"
  [ "$status" -eq 0 ]
  # the mock emits exactly one .d.ts per --grpc-web_out pass; the directory must not be counted
  [[ "$output" == *"files generated by proto compilation: 1"* ]]
  [[ "$output" != *"files generated by proto compilation: 2"* ]]
}

# ---------------------------------------------------------------------------
# 2. compile-proto-2-typescript.sh: the import scan
# ---------------------------------------------------------------------------

@test "ts-deps: a DIRECTORY named *.proto in the protos dir does not break the import scan" {
  # The scan used to `cat` every find hit, so a directory produced a "Is a directory"
  # error on stderr for every run.
  stage
  write_proto test.proto 'import "google/protobuf/timestamp.proto";'
  mkdir -p "$IN/protos/library/bogus.proto"
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Is a directory"* ]]
  [ "$(deps_file)" = "google/protobuf/timestamp.proto" ]
}

# ---------------------------------------------------------------------------
# 3. compile-proto-2-typescript.sh: the proto-deps.txt normalisation + dedup
# ---------------------------------------------------------------------------

@test "ts-deps: a client-supplied proto-deps.txt entry survives verbatim" {
  # This is the shipped example: typescript/example/proto-deps.txt holds the bare path
  # "dependency/myimport.proto". The pre-seeded file is copied in with the rest of the
  # mount, and the old positional `cut -c 8-` chopped 7 characters off it, turning it into
  # "ncy/myimport.proto" - a path protoc cannot resolve, which aborted the whole build.
  stage
  printf 'dependency/myimport.proto\n' > "$IN/proto-deps.txt"
  write_proto test.proto 'import "dependency/myimport.proto";'
  mkdir -p "$IN/protos/dependency"
  printf 'syntax = "proto3";\nmessage MyImport {}\n' > "$IN/protos/dependency/myimport.proto"
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(deps_file)" = "dependency/myimport.proto" ]
  # and the dependency pass really compiled that path
  run grep -Fq " dependency/myimport.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "ts-deps: a commented-out google import is ignored and does not delete the others" {
  # `// import "google/protobuf/struct.proto";` used to be picked up by the `grep import`
  # scan, then `cut -c 7-` reduced it to the token "ort", which as an unanchored grep
  # pattern matched EVERY import line in the list - so lines 2..N were all deleted and the
  # library silently shipped without the well-known types it imports.
  stage
  write_proto test.proto \
    'import "google/protobuf/timestamp.proto";' \
    '// import "google/protobuf/struct.proto";' \
    'import "google/protobuf/empty.proto";' \
    'import "google/api/annotations.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  echo "deps: $(deps_file)"
  [ "$(deps_count)" -eq 3 ]
  [ "$(deps_file)" = "google/api/annotations.proto
google/protobuf/empty.proto
google/protobuf/timestamp.proto" ]
  # all three reach the dependency protoc pass ...
  run grep -Fq "google/protobuf/empty.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq "google/api/annotations.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # ... and the commented-out one does not
  run grep -Fq "struct.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "ts-deps: an indented import yields the bare path, not a mangled token" {
  # A leading tab/space shifts the statement, so the positional cut produced "t google/..."
  # and the grep token "port" matched every other import line and deleted it.
  stage
  write_proto test.proto \
    '  import "google/protobuf/timestamp.proto";' \
    'import "google/protobuf/empty.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  echo "deps: $(deps_file)"
  [ "$(deps_file)" = "google/protobuf/empty.proto
google/protobuf/timestamp.proto" ]
}

@test "ts-deps: 'import public' yields the bare path, not a 'public ...' token" {
  # `import public` is legal proto3. The positional cut left the keyword in the path, and
  # the word "public" then leaked into the list protoc is handed.
  stage
  write_proto test.proto \
    'import public "google/protobuf/timestamp.proto";' \
    'import weak "google/protobuf/empty.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  echo "deps: $(deps_file)"
  [ "$(deps_file)" = "google/protobuf/empty.proto
google/protobuf/timestamp.proto" ]
  run grep -Eq '(^| )(public|weak) ' "$TEMP_SRC/proto-deps.txt"
  [ "$status" -ne 0 ]
}

@test "ts-deps: a dependency listed twice is collapsed to one entry, not dropped" {
  # `sort | uniq -u` prints only the lines that occur EXACTLY once, so a duplicated entry
  # was removed from the list altogether and protoc never generated that dependency's stubs.
  stage
  printf 'google/protobuf/empty.proto\ngoogle/protobuf/empty.proto\ngoogle/protobuf/timestamp.proto\n' \
    > "$IN/proto-deps.txt"
  write_proto test.proto 'import "google/protobuf/timestamp.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  echo "deps: $(deps_file)"
  [ "$(deps_file)" = "google/protobuf/empty.proto
google/protobuf/timestamp.proto" ]
  run grep -Fq "google/protobuf/empty.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "ts-deps: the same dependency pre-seeded AND imported is listed exactly once" {
  # Both halves of the fix are needed here: the pre-seeded bare path has to survive
  # normalisation intact, and the resulting duplicate has to be collapsed rather than
  # annihilated by uniq -u.
  stage
  printf 'google/protobuf/empty.proto\n' > "$IN/proto-deps.txt"
  write_proto test.proto 'import "google/protobuf/empty.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  echo "deps: $(deps_file)"
  [ "$(deps_count)" -eq 1 ]
  [ "$(deps_file)" = "google/protobuf/empty.proto" ]
}

# The three cases below already held before the fix; they are here so the rewrite of the
# deps pipeline cannot regress the behaviour it had to preserve.

@test "ts-deps: a dependency imported by two different protos is listed once" {
  stage
  write_proto a.proto 'import "google/protobuf/timestamp.proto";'
  write_proto b.proto 'import "google/protobuf/timestamp.proto";' 'import "google/protobuf/empty.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  echo "deps: $(deps_file)"
  [ "$(deps_file)" = "google/protobuf/empty.proto
google/protobuf/timestamp.proto" ]
}

@test "ts-deps: protos with no google imports leave the deps list empty and still build" {
  stage
  write_proto test.proto 'import "dependency/myimport.proto";'
  mkdir -p "$IN/protos/dependency"
  printf 'syntax = "proto3";\nmessage MyImport {}\n' > "$IN/protos/dependency/myimport.proto"
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(deps_count)" -eq 0 ]
  # exactly one protoc pass: the entry set. No empty dependency invocation.
  [ "$(grep -c '^protoc ' "$PROTOC_MOCK_LOG")" -eq 1 ]
}

@test "ts-deps: the mounted input volume is never mutated by the deps resolution" {
  stage
  printf 'dependency/myimport.proto\n' > "$IN/proto-deps.txt"
  write_proto test.proto 'import "google/protobuf/timestamp.proto";'
  mkdir -p "$IN/protos/dependency"
  printf 'syntax = "proto3";\nmessage MyImport {}\n' > "$IN/protos/dependency/myimport.proto"
  before="$(snapshot "$IN")"
  run_compile protos library
  [ "$status" -eq 0 ]
  after="$(snapshot "$IN")"
  [ "$before" = "$after" ]
  # the resolved list was built in the copy, not in the mount
  [ -f "$TEMP_SRC/proto-deps.txt" ]
  [ ! -e "$TEMP_SRC/proto-deps.txt.tmp" ]
  [ ! -e "$TEMP_SRC/proto-deps.txt.bak" ]
}

# ---------------------------------------------------------------------------
# 4. make-lib-entry-point.sh: find without -type f
# ---------------------------------------------------------------------------

@test "ts entry point: a DIRECTORY named *.d.ts is not exported from the barrel" {
  # find without -type f matched directories too, emitting a barrel line for a folder that
  # resolves to nothing (TS2307) - the js target already carries -type f here.
  SRC="$SANDBOX/src"
  mkdir -p "$SRC/api/ondewo/nlu" "$SRC/api/vendor.d.ts"
  printf 'export class DetectIntentRequest {}\n' > "$SRC/api/ondewo/nlu/session_pb.d.ts"
  printf 'export class Inner {}\n' > "$SRC/api/vendor.d.ts/inner.d.ts"

  run bash -c "cd '$REPO_ROOT/typescript/image-data' && bash ./make-lib-entry-point.sh '$SRC' .d.ts"
  echo "$output"
  [ "$status" -eq 0 ]
  cat "$SRC/public-api.d.ts"

  # the barrel strips the last extension, so the directory would be exported as
  # './api/vendor.d' -- distinct from the real stub nested inside it
  run grep -Fq "from './api/vendor.d';" "$SRC/public-api.d.ts"
  [ "$status" -ne 0 ]
  # the real stubs, including the one nested inside that directory, are still exported
  grep -Fq "export * from './api/ondewo/nlu/session_pb.d';" "$SRC/public-api.d.ts"
  grep -Fq "export * from './api/vendor.d.ts/inner.d';" "$SRC/public-api.d.ts"
}
