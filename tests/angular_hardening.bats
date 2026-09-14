#!/usr/bin/env bats
# Hardening of the angular target's two file-discovery scripts, bringing them level with the
# six targets hardened in 5.15.0.
#
# Both scripts selected their inputs by NAME alone (`find ... -iname "*.proto"` /
# `-iname "*.ts"`), and `find` matches a DIRECTORY whose name ends in the extension just as
# happily as a file. That is not a theoretical shape: the input volume is the client repo's
# `src`, staged with `cp -r`, and a stale generated tree or a vendored checkout can easily put
# a `something.proto/` or `legacy.ts/` in the way.
#
# What the two scripts did with such an entry differed, and both outcomes were wrong:
#   * compile-proto-2-stubs.sh counted it as a proto - so a directory ALONE satisfied the
#     no-protos guard - and then passed it to protoc as a positional input;
#   * generate-public-api.sh emitted an `export * from './api/.../legacy';` line for it, which
#     breaks the CONSUMER's build with TS2307 rather than this one's.
#
# The fix filters with `[ -f ]` rather than find's own `-type f`, because the input volume is
# staged with `cp -r` and keeps symlinks verbatim: a `.proto`/`.ts` a client symlinked in is a
# real module and `-type f` (which does not follow links) would silently drop it. The tests
# below pin BOTH halves - the decoy directory is excluded, the symlink is not.
#
# The proto3 explicit-presence codemod is deliberately untouched by all of this; the last case
# re-pins the descriptor-before-strip ordering it depends on, from this file's angle.

load 'helpers/setup'

setup() {
  common_setup
  STUBS_SH="$REPO_ROOT/angular/image-data/compile-proto-2-stubs.sh"
  GEN="$REPO_ROOT/angular/image-data/generate-public-api.sh"
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  SRC="$SANDBOX/src"
  OUT="$SANDBOX/out"
  mkdir -p "$SRC"
}
teardown() { common_teardown; }

# A real .proto in the source dir, so cases about a decoy have something valid beside it.
real_proto() {
  printf 'syntax = "proto3";\nmessage Real {\n  optional bool flag = 1;\n}\n' > "$SRC/real.proto"
}

run_stubs() {
  run bash "$STUBS_SH" "$OUT" "$SRC" "$SRC"
}

# ---------------------------------------------------------------------------
# compile-proto-2-stubs.sh: a DIRECTORY named *.proto
# ---------------------------------------------------------------------------

@test "angular stubs: a DIRECTORY named *.proto does not satisfy the no-protos guard" {
  # The guard is the only thing standing between an empty/mis-mounted volume and a protoc run
  # over nothing. A decoy directory used to count as one proto and let the whole pipeline run.
  mkdir -p "$SRC/not-a-file.proto"

  run_stubs
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found in"* ]]
  # nothing was compiled, and no stub tree was left behind
  [ ! -f "$PROTOC_MOCK_LOG" ]
  [ ! -e "$OUT" ]
}

@test "angular stubs: a DIRECTORY named *.proto is never handed to protoc" {
  # protoc aborts with its own "Is a directory" on a positional directory - an error about the
  # toolchain, for what is really a bad input this script is supposed to describe.
  real_proto
  mkdir -p "$SRC/decoy.proto"

  run_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 1 .proto files"* ]]

  run grep -Fq -- "$SRC/decoy.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # the real proto beside it is still compiled, by both passes
  [ "$(grep -c -- " $SRC/real.proto" "$PROTOC_MOCK_LOG")" -eq 2 ]
}

@test "angular stubs: the decoy directory is excluded from the descriptor pass too" {
  # The descriptor set is what the presence codemod replays over the stubs; a directory in that
  # invocation would fail the recording step before protoc-gen-ng ever runs.
  real_proto
  mkdir -p "$SRC/decoy.proto"

  run_stubs
  [ "$status" -eq 0 ]

  run head -1 "$PROTOC_MOCK_LOG"
  [[ "$output" == *"--descriptor_set_out="* ]]
  [[ "$output" != *"decoy.proto"* ]]
}

@test "angular stubs: the optional-strip pass skips a decoy directory" {
  # `sed -i.bak` on a directory fails; the strip loop must never see one.
  real_proto
  mkdir -p "$SRC/decoy.proto"

  run_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removing 'optional ' from file: $SRC/real.proto"* ]]
  [[ "$output" != *"Removing 'optional ' from file: $SRC/decoy.proto"* ]]
  # the real proto really was stripped
  run grep -c "optional bool" "$SRC/real.proto"
  [ "$output" = "0" ]
}

@test "angular stubs: the consumed-files banner lists no decoy directory" {
  real_proto
  mkdir -p "$SRC/decoy.proto"

  run_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"Consuming .proto files: $SRC/real.proto: "* ]]
}

# ---------------------------------------------------------------------------
# compile-proto-2-stubs.sh: symlinked protos must survive the filter
# ---------------------------------------------------------------------------

@test "angular stubs: a symlinked .proto is still compiled" {
  # Guards the fix against the naive spelling: find's own -type f does NOT follow symlinks, so
  # it would drop a vendored proto the client linked into its protos dir - a silently missing
  # service in the generated client.
  real_proto
  mkdir -p "$SANDBOX/vendor"
  printf 'syntax = "proto3";\nmessage Extra {}\n' > "$SANDBOX/vendor/extra.proto"
  ln -s ../vendor/extra.proto "$SRC/extra.proto"

  run_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 2 .proto files"* ]]
  run grep -Fq -- " $SRC/extra.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "angular stubs: a protos dir holding only a symlinked .proto passes the guard" {
  mkdir -p "$SANDBOX/vendor"
  printf 'syntax = "proto3";\nmessage Only {}\n' > "$SANDBOX/vendor/only.proto"
  ln -s ../vendor/only.proto "$SRC/only.proto"

  run_stubs
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 1 .proto files"* ]]
}

@test "angular stubs: a .proto symlink that dangles fails loudly instead of vanishing" {
  # `[ -f ]` alone would drop it without a word once the naming filter stopped being the only
  # gate - and a silently missing proto is a silently missing service.
  real_proto
  ln -s /nowhere/gone.proto "$SRC/gone.proto"

  run_stubs
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not resolve to a file"* ]]
  [[ "$output" == *"gone.proto"* ]]
  [ ! -f "$PROTOC_MOCK_LOG" ]
}

@test "angular stubs: a .proto symlink pointing at a DIRECTORY fails loudly" {
  real_proto
  mkdir -p "$SANDBOX/adir"
  ln -s "$SANDBOX/adir" "$SRC/linked.proto"

  run_stubs
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not resolve to a file"* ]]
  [[ "$output" == *"linked.proto"* ]]
}

# ---------------------------------------------------------------------------
# compile-proto-2-stubs.sh: the generated-stub count
# ---------------------------------------------------------------------------

@test "angular stubs: a DIRECTORY named *.ts in the stubs tree is not counted as output" {
  # The count is informational, but it is the one place that reports how much protoc-gen-ng
  # produced - a directory must never inflate it.
  real_proto
  mkdir -p "$SANDBOX/countbin"
  cat > "$SANDBOX/countbin/protoc" <<'MOCK'
#!/usr/bin/env bash
# protoc shim: one real stub plus a DIRECTORY whose name ends in .ts
for a in "$@"; do
  case "$a" in
    --descriptor_set_out=*) printf '\012\014\012\012mock.proto' > "${a#*=}" ;;
    --ng_out=*) d="${a#--ng_out=}"; mkdir -p "$d/nested.ts"; : > "$d/mock_pb.ts" ;;
  esac
done
MOCK
  chmod +x "$SANDBOX/countbin/protoc"
  PATH="$SANDBOX/countbin:$PATH"

  run_stubs
  [ "$status" -eq 0 ]
  [ -d "$OUT/nested.ts" ]
  [[ "$output" == *"files generated by proto compilation: 1"* ]]
}

# ---------------------------------------------------------------------------
# generate-public-api.sh: a DIRECTORY named *.ts under api/
# ---------------------------------------------------------------------------

@test "generate-public-api: a DIRECTORY named *.ts under api/ earns no export line" {
  # This one does not break the compiler image - it ships a barrel whose dangling line fails
  # the CLIENT's `ng build` with TS2307, far away from anything that points back here.
  local root="$SANDBOX/barrel" out_file
  out_file="$root/public-api.ts"
  mkdir -p "$root/api/ondewo/nlu"
  printf 'export class DetectIntentRequest {}\n' > "$root/api/ondewo/nlu/session.pb.ts"
  mkdir -p "$root/api/ondewo/nlu/legacy.ts"
  : > "$out_file"

  run bash "$GEN" "$root" "$out_file"
  [ "$status" -eq 0 ]

  run grep -Fq "legacy" "$out_file"
  [ "$status" -ne 0 ]
  # the real stub beside it is still star-exported
  grep -Fq "export * from './api/ondewo/nlu/session.pb';" "$out_file"
}

@test "generate-public-api: a DIRECTORY named *.ts does not reach the duplicate scan" {
  # The second pass feeds every match to awk as an input FILE; a directory there is an awk
  # error on stderr and, worse, a candidate for an explicit re-export.
  local root="$SANDBOX/barrel" out_file
  out_file="$root/public-api.ts"
  mkdir -p "$root/api/ondewo/nlu" "$root/api/ondewo/s2t"
  printf 'export enum ReasoningEffort {}\n' > "$root/api/ondewo/nlu/session.pb.ts"
  printf 'export enum ReasoningEffort {}\n' > "$root/api/ondewo/s2t/speech-to-text.pb.ts"
  mkdir -p "$root/api/ondewo/decoy.ts"
  : > "$out_file"

  run bash "$GEN" "$root" "$out_file"
  [ "$status" -eq 0 ]
  [[ "$output" != *"decoy.ts"* ]]

  # the genuine collision is still disambiguated, exactly once, against a real stub
  grep -Fq "export { ReasoningEffort } from './api/ondewo/nlu/session.pb';" "$out_file"
  run grep -c "^export {" "$out_file"
  [ "$output" = "1" ]
  run grep -Fq "decoy" "$out_file"
  [ "$status" -ne 0 ]
}

@test "generate-public-api: a symlinked stub under api/ keeps its export" {
  # Guards the fix against find -type f, which would drop it and make the symlinked module
  # unreachable for every consumer of the library.
  local root="$SANDBOX/barrel" out_file
  out_file="$root/public-api.ts"
  mkdir -p "$root/api/ondewo/nlu" "$SANDBOX/vendored"
  printf 'export class DetectIntentRequest {}\n' > "$root/api/ondewo/nlu/session.pb.ts"
  printf 'export class VendoredRequest {}\n'     > "$SANDBOX/vendored/vendored.pb.ts"
  ln -s "$SANDBOX/vendored/vendored.pb.ts" "$root/api/ondewo/nlu/vendored.pb.ts"
  : > "$out_file"

  run bash "$GEN" "$root" "$out_file"
  [ "$status" -eq 0 ]
  grep -Fq "export * from './api/ondewo/nlu/vendored.pb';" "$out_file"
  # and its symbols are indexed, so a collision with it would still be disambiguated
  grep -Fq "export * from './api/ondewo/nlu/session.pb';" "$out_file"
}

# ---------------------------------------------------------------------------
# the presence codemod's contract, from this file's angle
# ---------------------------------------------------------------------------

@test "angular stubs: filtering the inputs did not disturb the descriptor-before-strip order" {
  # The descriptor set is the ONLY artifact that still carries proto3_optional; taken after the
  # strip it would mark nothing and the codemod would ship a client that cannot send false/0/"".
  real_proto
  mkdir -p "$SRC/decoy.proto"
  mkdir -p "$SANDBOX/orderbin"
  cat > "$SANDBOX/orderbin/protoc" <<'MOCK'
#!/usr/bin/env bash
optional_count=0
for a in "$@"; do
  case "$a" in
    *.proto) optional_count=$((optional_count + $(grep -c '^[[:space:]]*optional ' "$a" || true))) ;;
    --descriptor_set_out=*) printf '\012\014\012\012mock.proto' > "${a#*=}" ;;
    --ng_out=*) mkdir -p "${a#*=}" && : > "${a#*=}/mock_pb.ts" ;;
  esac
done
printf '%s optional=%s\n' "$*" "$optional_count" >> "$ORDER_LOG"
MOCK
  chmod +x "$SANDBOX/orderbin/protoc"
  ORDER_LOG="$SANDBOX/order.log"
  export ORDER_LOG
  PATH="$SANDBOX/orderbin:$PATH"

  run_stubs
  [ "$status" -eq 0 ]

  run head -1 "$ORDER_LOG"
  [[ "$output" == *"--descriptor_set_out="* ]]
  [[ "$output" == *"optional=1"* ]]

  run sed -n '2p' "$ORDER_LOG"
  [[ "$output" == *"--ng_out="* ]]
  [[ "$output" == *"optional=0"* ]]
}
