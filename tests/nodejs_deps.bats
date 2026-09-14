#!/usr/bin/env bats
# The nodejs target's google-dependency resolution: how an `import` statement in a .proto
# becomes a line in proto-deps.txt, and what compile-proto-2-stubs.sh is then handed.
# Everything runs on the HOST - the container paths come from the env knobs the scripts
# expose and protoc / grpc_tools_node_protoc / npm are PATH-mocked - so no Docker is needed.
#
# The resolution used to parse import statements POSITIONALLY (`cut -c 7-` / `cut -c 8-`,
# i.e. "the path starts at column 8") and dedup them by grepping the collected line list
# with each extracted token as an unanchored REGEX, deleting the matched line numbers with
# sed. Three defects compounded, all of them silent - the build exited 0 and shipped a
# library whose stubs were missing or whose import paths were nonsense:
#
#   * an indented import, or a legal `import public` / `import weak`, was chopped at the
#     wrong column, so the token that landed in proto-deps.txt was a mangled path
#     ("public google/...", " google/...") that protoc cannot resolve;
#   * a mangled token that happens to be a substring of the word "import" - which is what
#     an indented import or a commented-out `// import "google/...";` produces - matched
#     EVERY other line in the list, and the sed then deleted all of them: a single comment
#     line could reduce a four-entry dependency list to one;
#   * the closing `sort | uniq -u` prints only the lines that occur EXACTLY once, so a
#     dependency that did end up listed twice was dropped from the list altogether instead
#     of being collapsed to a single entry.
#
# The typescript target carried the identical block and is fixed the same way: the quoted
# path is parsed out of the statement with an anchored sed, and the list is collapsed with
# `sort -u`.

load 'helpers/setup'

setup() {
  common_setup
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  export NPM_MOCK_LOG="$SANDBOX/npm.log"

  IN="$SANDBOX/input"
  OUT="$SANDBOX/output"
  mkdir -p "$IN/protos/library" "$OUT"
  printf '{"name":"fixture","version":"0.0.1"}\n' > "$IN/package.json"
}

teardown() { common_teardown; }

# Copy nodejs/image-data into the sandbox and cd there (the orchestrator invokes its
# siblings as ./x.sh and stages into $IMAGE_DATA_DIRECTORY), then point the container-path
# knobs at the sandbox. TEMP_SRC is the script's OWN default ($IMAGE_DATA_DIRECTORY/src)
# and is deliberately left unset in the environment, so that default is under test too.
stage() {
  cp -r "$REPO_ROOT/nodejs/image-data" "$SANDBOX/image-data"
  cd "$SANDBOX/image-data"
  export IMAGE_DATA_DIRECTORY="$SANDBOX/image-data"
  export INPUT_VOLUME_FS="$IN"
  export OUTPUT_VOLUME_FS="$OUT"
  TEMP_SRC="$SANDBOX/image-data/src"
}

run_compile() { run bash ./compile-proto-2-nodejs.sh "$@"; }

# The resolved dependency list the orchestrator hands to compile-proto-2-stubs.sh.
deps_file() { cat "$TEMP_SRC/proto-deps.txt"; }

# Number of non-blank lines in that list (grep -c, never wc: BSD pads with spaces).
deps_count() { grep -c '[^[:space:]]' "$TEMP_SRC/proto-deps.txt" || true; }

# Content + layout fingerprint of a tree, used to prove the mount is only ever read.
snapshot() { (cd "$1" && find . -print | sort && find . -type f -exec cksum {} + | sort); }

# write_proto <path> <line...>: a proto carrying the given lines verbatim, so a test can
# spell an import exactly as it wants (indented, commented out, `import public`, ...).
write_proto() {
  local target=$1
  shift
  mkdir -p "$(dirname "$target")"
  {
    printf 'syntax = "proto3";\n'
    printf '%s\n' "$@"
    printf 'message T { string name = 1; }\n'
  } > "$target"
}

# ---------------------------------------------------------------------------
# the import scan: one statement -> one bare path
# ---------------------------------------------------------------------------

@test "node-deps: a google type imported by two protos, one of them indented, keeps BOTH deps" {
  # The headline regression. a.proto indents its import by one space; the positional
  # `cut -c 7-` then yielded the token "t", which as an unanchored grep pattern matched
  # every line in the list, and lines 2..N were deleted - so google/protobuf/timestamp.proto
  # vanished from the dependency list entirely and the surviving entry came out as
  # " google/protobuf/empty.proto", a path protoc cannot resolve.
  stage
  write_proto "$IN/protos/library/a.proto" ' import "google/protobuf/empty.proto";'
  write_proto "$IN/protos/library/b.proto" \
    'import "google/protobuf/empty.proto";' \
    'import "google/protobuf/timestamp.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  echo "deps: [$(deps_file)]"
  [ "$(deps_count)" -eq 2 ]
  [ "$(deps_file)" = "google/protobuf/empty.proto
google/protobuf/timestamp.proto" ]
  # both really reach the dependency protoc pass, as bare paths
  run grep -Fq " google/protobuf/empty.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq " google/protobuf/timestamp.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "node-deps: a commented-out google import is ignored and does not delete the others" {
  # `// import "google/protobuf/struct.proto";` was picked up by the `grep import` scan,
  # `cut -c 7-` reduced it to the token "ort", and that matched EVERY import line in the
  # list - so everything but the first entry was deleted and the library silently shipped
  # without the well-known types it imports.
  stage
  write_proto "$IN/protos/library/a.proto" \
    'import "google/protobuf/timestamp.proto";' \
    '// import "google/protobuf/struct.proto";' \
    'import "google/protobuf/empty.proto";' \
    'import "google/api/annotations.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  echo "deps: [$(deps_file)]"
  [ "$(deps_count)" -eq 3 ]
  [ "$(deps_file)" = "google/api/annotations.proto
google/protobuf/empty.proto
google/protobuf/timestamp.proto" ]
  # all three reach the dependency protoc pass ...
  run grep -Fq " google/protobuf/empty.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq " google/api/annotations.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # ... and the commented-out one does not
  run grep -Fq "struct.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "node-deps: 'import public' / 'import weak' yield the bare path, not a keyword token" {
  # Both spellings are legal proto3. The positional cut left the keyword inside the path,
  # so "public google/protobuf/timestamp.proto" was handed to protoc as an input file.
  stage
  write_proto "$IN/protos/library/a.proto" \
    'import public "google/protobuf/timestamp.proto";' \
    'import weak "google/protobuf/empty.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  echo "deps: [$(deps_file)]"
  [ "$(deps_file)" = "google/protobuf/empty.proto
google/protobuf/timestamp.proto" ]
  run grep -Eq '(^| )(public|weak) ' "$TEMP_SRC/proto-deps.txt"
  [ "$status" -ne 0 ]
}

@test "node-deps: a tab between the keyword and the path yields the bare path" {
  stage
  printf 'syntax = "proto3";\nimport\t"google/protobuf/empty.proto";\nmessage T {}\n' \
    > "$IN/protos/library/a.proto"
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(deps_file)" = "google/protobuf/empty.proto" ]
}

# ---------------------------------------------------------------------------
# a client-supplied proto-deps.txt
# ---------------------------------------------------------------------------

@test "node-deps: a client-supplied proto-deps.txt entry survives verbatim" {
  # This is the shipped example: nodejs/example/proto-deps.txt holds the bare path
  # "dependency/myimport.proto". It is copied in with the rest of the mount, and the
  # positional `cut -c 8-` chopped 7 characters off it, leaving "ncy/myimport.proto" -
  # a path protoc cannot resolve.
  stage
  printf 'dependency/myimport.proto\n' > "$IN/proto-deps.txt"
  write_proto "$IN/protos/library/a.proto" 'import "dependency/myimport.proto";'
  write_proto "$IN/protos/dependency/myimport.proto"
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(deps_file)" = "dependency/myimport.proto" ]
  # and the dependency pass really compiled that path
  run grep -Fq " dependency/myimport.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "node-deps: a dependency listed twice in the seeded file is collapsed, not dropped" {
  # `sort | uniq -u` prints only the lines that occur EXACTLY once, so a duplicated entry
  # was removed from the list altogether and protoc never generated that dependency's stubs.
  stage
  printf 'google/protobuf/empty.proto\ngoogle/protobuf/empty.proto\ngoogle/protobuf/timestamp.proto\n' \
    > "$IN/proto-deps.txt"
  write_proto "$IN/protos/library/a.proto"
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  echo "deps: [$(deps_file)]"
  [ "$(deps_file)" = "google/protobuf/empty.proto
google/protobuf/timestamp.proto" ]
  run grep -Fq " google/protobuf/empty.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "node-deps: the same dependency seeded AND imported is listed exactly once" {
  # Both halves of the fix are needed here: the seeded bare path has to survive the
  # normalisation intact, and the resulting duplicate has to be collapsed by `sort -u`
  # rather than annihilated by `uniq -u`.
  stage
  printf 'google/protobuf/empty.proto\n' > "$IN/proto-deps.txt"
  write_proto "$IN/protos/library/a.proto" 'import "google/protobuf/empty.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  echo "deps: [$(deps_file)]"
  [ "$(deps_count)" -eq 1 ]
  [ "$(deps_file)" = "google/protobuf/empty.proto" ]
}

# ---------------------------------------------------------------------------
# the sibling google/ tree is scanned by the same parser
# ---------------------------------------------------------------------------

@test "node-deps: the google/ tree's own imports are parsed, not chopped" {
  # The transitive scan over the sibling google/ directory appends to the same list and so
  # had the same defects: an indented import there mangled the entry and its "t" token
  # deleted the library protos' entries as well.
  stage
  write_proto "$IN/protos/library/a.proto" 'import "google/api/annotations.proto";'
  write_proto "$IN/protos/google/api/annotations.proto" \
    '  import "google/protobuf/descriptor.proto";' \
    'import public "google/protobuf/duration.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Google: For loop:"* ]]
  echo "deps: [$(deps_file)]"
  [ "$(deps_count)" -eq 3 ]
  [ "$(deps_file)" = "google/api/annotations.proto
google/protobuf/descriptor.proto
google/protobuf/duration.proto" ]
}

@test "node-deps: the google/ exclusion list still keeps the ignored trees out" {
  # Guard on the filters the scan already had, so the parser rewrite cannot widen them.
  stage
  write_proto "$IN/protos/library/a.proto" 'import "google/api/annotations.proto";'
  write_proto "$IN/protos/google/api/annotations.proto" 'import "google/protobuf/descriptor.proto";'
  # matches the include filter ("api") but is excluded by "vision"
  write_proto "$IN/protos/google/vision/api.proto" 'import "google/protobuf/struct.proto";'
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  run grep -Fq "google/protobuf/struct.proto" "$TEMP_SRC/proto-deps.txt"
  [ "$status" -ne 0 ]
  run grep -Fq "struct.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# invariants the rewrite must preserve
# ---------------------------------------------------------------------------

@test "node-deps: protos with no google imports leave the list empty and still build" {
  stage
  write_proto "$IN/protos/library/a.proto" 'import "dependency/myimport.proto";'
  write_proto "$IN/protos/dependency/myimport.proto"
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(deps_count)" -eq 0 ]
  # no empty dependency invocation: protoc is called once, for the entry set
  [ "$(grep -c '^protoc ' "$PROTOC_MOCK_LOG")" -eq 1 ]
}

@test "node-deps: the mounted input volume is never mutated by the deps resolution" {
  stage
  printf 'dependency/myimport.proto\n' > "$IN/proto-deps.txt"
  write_proto "$IN/protos/library/a.proto" 'import "google/protobuf/timestamp.proto";'
  write_proto "$IN/protos/dependency/myimport.proto"
  before="$(snapshot "$IN")"
  run_compile protos library
  echo "$output"
  [ "$status" -eq 0 ]
  after="$(snapshot "$IN")"
  [ "$before" = "$after" ]
  # the resolved list was built in the copy, not in the mount, and left no scratch files
  [ -f "$TEMP_SRC/proto-deps.txt" ]
  [ ! -e "$TEMP_SRC/proto-deps.txt.tmp" ]
  [ ! -e "$TEMP_SRC/proto-deps.txt.bak" ]
  [ ! -e "$TEMP_SRC/proto-deps-unique.txt" ]
}
