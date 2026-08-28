#!/usr/bin/env bats
# The angular proto3 explicit-presence codemod (angular/image-data/fix-proto3-optional-presence.ts).
#
# protoc-gen-ng emits byte-identical code for `optional bool x = 5` and plain `bool x = 5`, so the
# generated .ts alone cannot tell them apart and a text-only rewrite of both would be wire-breaking
# (a plain proto3 scalar MUST stay unwritten at its zero value). The codemod is therefore driven by
# a descriptor set, which is the only artifact that still carries proto3_optional.
#
# The fixtures under tests/fixtures/presence/ are REAL protoc / protoc-gen-ng output for
# presence.proto (regenerate with tests/fixtures/presence/regenerate.sh), so these cases assert
# against the shape the generator actually produces, not against a hand-written imitation.

load 'helpers/setup'

setup() {
  common_setup
  CODEMOD="$REPO_ROOT/angular/image-data/fix-proto3-optional-presence.ts"
  DESCRIPTOR="$FIXTURES/presence/presence.descriptor.bin"
  STUB_SOURCE="$FIXTURES/presence/presence.pb.ts"
  STUBS="$SANDBOX/api"
  STUB="$STUBS/presence.pb.ts"
  mkdir -p "$STUBS"
  cp "$STUB_SOURCE" "$STUB"
}
teardown() { common_teardown; }

@test "presence codemod: an optional scalar loses its refineValues coercion" {
  run node "$CODEMOD" "$DESCRIPTOR" "$STUBS"
  [ "$status" -eq 0 ]
  # The coercion ran from the constructor and destroyed presence before the writer ever saw it.
  run grep -Fq "_instance.optionalFlag = _instance.optionalFlag || false;" "$STUB"
  [ "$status" -ne 0 ]
  run grep -Fq "_instance.optionalText = _instance.optionalText || '';" "$STUB"
  [ "$status" -ne 0 ]
  run grep -Fq "_instance.optionalSize = _instance.optionalSize || '0';" "$STUB"
  [ "$status" -ne 0 ]
}

@test "presence codemod: an optional scalar's writer guard tests presence, not truthiness" {
  run node "$CODEMOD" "$DESCRIPTOR" "$STUBS"
  [ "$status" -eq 0 ]
  # Short enough to stay on one line at protoc-gen-ng's 80-column formatting ...
  run grep -Fq "if (_instance.nestedFlag !== undefined && _instance.nestedFlag !== null) {" "$STUB"
  [ "$status" -eq 0 ]
  # ... and wrapped the way prettier would when it is not.
  run grep -Fq "_instance.optionalFlag !== undefined &&" "$STUB"
  [ "$status" -eq 0 ]
  run grep -Fq "_instance.optionalFlag !== null" "$STUB"
  [ "$status" -eq 0 ]
}

@test "presence codemod: a plain proto3 scalar is left exactly as generated" {
  run node "$CODEMOD" "$DESCRIPTOR" "$STUBS"
  [ "$status" -eq 0 ]
  # This is the regression that would change what every existing ondewo client sends.
  run grep -Fq "_instance.plainFlag = _instance.plainFlag || false;" "$STUB"
  [ "$status" -eq 0 ]
  run grep -Fq "if (_instance.plainFlag) {" "$STUB"
  [ "$status" -eq 0 ]
  run grep -Fq "_instance.plainText = _instance.plainText || '';" "$STUB"
  [ "$status" -eq 0 ]
  run grep -Fq "if (_instance.plainView) {" "$STUB"
  [ "$status" -eq 0 ]
  run grep -Fq "_instance.plainList = _instance.plainList || [];" "$STUB"
  [ "$status" -eq 0 ]
}

@test "presence codemod: a message-typed optional field is left untouched" {
  run node "$CODEMOD" "$DESCRIPTOR" "$STUBS"
  [ "$status" -eq 0 ]
  # A message is either an object or absent, so the generated guard is already exact.
  run grep -Fq "_instance.optionalMessage = _instance.optionalMessage || undefined;" "$STUB"
  [ "$status" -eq 0 ]
  run grep -Fq "if (_instance.optionalMessage) {" "$STUB"
  [ "$status" -eq 0 ]
}

@test "presence codemod: a nested message is matched by its fully qualified class id" {
  run node "$CODEMOD" "$DESCRIPTOR" "$STUBS"
  [ "$status" -eq 0 ]
  run grep -Fq "if (_instance.innerText !== undefined && _instance.innerText !== null) {" "$STUB"
  [ "$status" -eq 0 ]
  run grep -Fq "_instance.plainInnerText = _instance.plainInnerText || '';" "$STUB"
  [ "$status" -eq 0 ]
}

@test "presence codemod: the reader is deliberately not rewritten" {
  run node "$CODEMOD" "$DESCRIPTOR" "$STUBS"
  [ "$status" -eq 0 ]
  # Presence on the read path is restored by dropping the refineValues coercion; the per-field
  # branch already runs only when the field is on the wire.
  run grep -Fq "_instance.optionalFlag = _reader.readBool();" "$STUB"
  [ "$status" -eq 0 ]
  run grep -Fq "PresenceFixture.refineValues(_instance);" "$STUB"
  [ "$status" -eq 0 ]
}

@test "presence codemod: no line outside a presence-bearing field changes" {
  run node "$CODEMOD" "$DESCRIPTOR" "$STUBS"
  [ "$status" -eq 0 ]
  # Guard the guard: an unchanged file would satisfy the scope check vacuously.
  run bash -c "diff '$STUB_SOURCE' '$STUB' | grep -cE '^[<>]' || true"
  [ "$output" -gt 0 ]
  # Every differing line must name one of the fields presence.proto declares optional and that
  # are not message-typed. Anything else is a field the codemod had no business touching.
  run bash -c "diff '$STUB_SOURCE' '$STUB' | grep -E '^[<>]' | \
    grep -vE 'optionalFlag|optionalText|optionalCount|optionalView|optionalSize|optionalRatio|nestedFlag|outerFlag|innerText' | \
    grep -vE '^[<>][[:space:]]*(if \(|\) \{|_writer\.write)' | grep -c . || true"
  [ "$output" = "0" ]
}

@test "presence codemod: reports what it rewrote" {
  run node "$CODEMOD" "$DESCRIPTOR" "$STUBS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rewrote 9 field(s) in 4 message(s)"* ]]
  [[ "$output" == *"1 message-typed optional field(s)"* ]]
}

@test "presence codemod: a missing descriptor set fails loudly" {
  run node "$CODEMOD" "$SANDBOX/absent.bin" "$STUBS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "presence codemod: an empty descriptor set is a broken inspection, not an empty answer" {
  : > "$SANDBOX/empty.bin"
  run node "$CODEMOD" "$SANDBOX/empty.bin" "$STUBS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"describes no .proto file"* ]]
}

@test "presence codemod: a descriptor message that no stub declares fails loudly" {
  rm -f "$STUB"
  printf 'export const unrelated = 1;\n' > "$STUBS/unrelated.ts"
  run node "$CODEMOD" "$DESCRIPTOR" "$STUBS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no generated stub declares"* ]]
}

@test "presence codemod: a generated shape it cannot match fails loudly" {
  # Stands in for a future protoc-gen-ng release changing its output: rewriting nothing while
  # reporting success would ship a client that silently drops explicitly set zero values.
  sed -i.bak 's/if (_instance.nestedFlag) {/if (_instance.nestedFlag != null) {/' "$STUB"
  rm -f "$STUB.bak"
  run node "$CODEMOD" "$DESCRIPTOR" "$STUBS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected 1 writer guard, found 0"* ]]
}

@test "angular stubs pipeline: the descriptor is taken before the optional keyword is stripped" {
  mkdir -p "$SANDBOX/bin" "$SANDBOX/src" "$SANDBOX/out"
  printf 'syntax = "proto3";\nmessage A {\n  optional bool flag = 1;\n}\n' > "$SANDBOX/src/a.proto"

  # A local protoc mock that records, per invocation, its flags AND how many optional field
  # declarations the inputs still carry - which is what tells the two passes apart.
  cat > "$SANDBOX/bin/protoc" <<'MOCK'
#!/usr/bin/env bash
optional_count=0
for a in "$@"; do
  case "$a" in
    *.proto) optional_count=$((optional_count + $(grep -c '^[[:space:]]*optional ' "$a" || true))) ;;
    --descriptor_set_out=*) printf '\012\014\012\012mock.proto' > "${a#*=}" ;;
    --ng_out=*) mkdir -p "${a#*=}" && : > "${a#*=}/mock_pb.ts" ;;
  esac
done
printf '%s optional=%s\n' "$*" "$optional_count" >> "$MOCK_LOG"
MOCK
  chmod +x "$SANDBOX/bin/protoc"
  MOCK_LOG="$SANDBOX/protoc-order.log"
  export MOCK_LOG
  PATH="$SANDBOX/bin:$PATH"

  run bash "$REPO_ROOT/angular/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/out" "$SANDBOX/src" "$SANDBOX/src"
  [ "$status" -eq 0 ]

  run head -1 "$MOCK_LOG"
  [[ "$output" == *"--descriptor_set_out="* ]]
  [[ "$output" == *"optional=1"* ]]

  run sed -n '2p' "$MOCK_LOG"
  [[ "$output" == *"--ng_out="* ]]
  [[ "$output" == *"optional=0"* ]]
}
