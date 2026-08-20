#!/usr/bin/env bats
# Unit tests for the js / nodejs / typescript make-lib-entry-point.sh scripts, which
# generate the public-api barrel each of those targets compiles or bundles.
#
# The angular target's barrel generator has its own file (public_api_barrel.bats); it
# was split out because it is shared by two call sites there.

load 'helpers/setup'

setup() {
  common_setup
  SRC="$SANDBOX/src"
  mkdir -p "$SRC/api/ondewo/nlu" "$SRC/api/ondewo/s2t"
}
teardown() { common_teardown; }

# Run a target's make-lib-entry-point.sh from its image-data dir (it resolves
# default-lib-files relative to the working directory).
run_entry_point() {
  local target=$1
  shift
  run bash -c "cd '$REPO_ROOT/$target/image-data' && bash ./make-lib-entry-point.sh '$SRC' $*"
}

# ----------------------------------------------------------------- js

@test "js entry point: does not star-export itself" {
  # public-api.js is copied from the default BEFORE the find runs, so an unpruned find
  # makes the webpack entry point import itself -- a circular self-reference.
  printf 'exports.A = 1;\n' > "$SRC/api/ondewo/nlu/session_pb.js"

  run_entry_point js
  [ "$status" -eq 0 ]

  run grep -c "public-api" "$SRC/public-api.js"
  [ "$output" = "0" ]
}

@test "js entry point: emits single-dot relative specifiers" {
  printf 'exports.A = 1;\n' > "$SRC/api/ondewo/nlu/session_pb.js"

  run_entry_point js
  [ "$status" -eq 0 ]

  grep -Fq "export * from './api/ondewo/nlu/session_pb';" "$SRC/public-api.js"
  run grep -c "'\./\./" "$SRC/public-api.js"
  [ "$output" = "0" ]
}

@test "js entry point: skips node_modules and webpack config, keeps hand-written sources" {
  printf 'exports.A = 1;\n' > "$SRC/api/ondewo/nlu/session_pb.js"
  mkdir -p "$SRC/node_modules/dep" "$SRC/auth"
  printf 'exports.B = 1;\n' > "$SRC/node_modules/dep/index.js"
  printf 'module.exports = {};\n' > "$SRC/webpack.js"
  printf 'exports.OfflineTokenProvider = 1;\n' > "$SRC/auth/offlineTokenProvider.js"

  run_entry_point js
  [ "$status" -eq 0 ]

  run grep -c "node_modules" "$SRC/public-api.js"
  [ "$output" = "0" ]
  run grep -c "webpack" "$SRC/public-api.js"
  [ "$output" = "0" ]
  grep -Fq "export * from './auth/offlineTokenProvider';" "$SRC/public-api.js"
}

# ------------------------------------------------- nodejs / typescript

# Both targets ship the same generator; assert each so a divergence is caught.
@test "nodejs/typescript entry point: star-exports every stub" {
  for target in nodejs typescript; do
    rm -f "$SRC/public-api.d.ts"
    printf 'export class DetectIntentRequest {}\n' > "$SRC/api/ondewo/nlu/session_pb.d.ts"
    printf 'export class TranscribeRequest {}\n'   > "$SRC/api/ondewo/s2t/s2t_pb.d.ts"

    run_entry_point "$target" .d.ts
    [ "$status" -eq 0 ]

    grep -Fq "export * from './api/ondewo/nlu/session_pb.d';" "$SRC/public-api.d.ts"
    grep -Fq "export * from './api/ondewo/s2t/s2t_pb.d';" "$SRC/public-api.d.ts"
  done
}

@test "nodejs/typescript entry point: disambiguates a symbol declared by two stubs (TS2308)" {
  for target in nodejs typescript; do
    rm -f "$SRC/public-api.d.ts"
    printf 'export class ReasoningEffort {}\nexport class DetectIntentRequest {}\n' \
      > "$SRC/api/ondewo/nlu/session_pb.d.ts"
    printf 'export class ReasoningEffort {}\nexport class TranscribeRequest {}\n' \
      > "$SRC/api/ondewo/s2t/s2t_pb.d.ts"

    run_entry_point "$target" .d.ts
    [ "$status" -eq 0 ]

    # bound to the first declaring stub in sorted order, and emitted exactly once
    grep -Fq "export { ReasoningEffort } from './api/ondewo/nlu/session_pb.d';" "$SRC/public-api.d.ts"
    run grep -c "^export { ReasoningEffort }" "$SRC/public-api.d.ts"
    [ "$output" = "1" ]
  done
}

@test "nodejs/typescript entry point: a name declared twice within one stub is not a collision" {
  for target in nodejs typescript; do
    rm -f "$SRC/public-api.d.ts"
    # the generator emits `export class X` and `export namespace X` for the same message
    printf 'export class DetectIntentRequest {}\nexport namespace DetectIntentRequest {}\n' \
      > "$SRC/api/ondewo/nlu/session_pb.d.ts"
    printf 'export class TranscribeRequest {}\n' > "$SRC/api/ondewo/s2t/s2t_pb.d.ts"

    run_entry_point "$target" .d.ts
    [ "$status" -eq 0 ]

    run grep -c '^export {' "$SRC/public-api.d.ts"
    [ "$output" = "0" ]
  done
}

@test "nodejs/typescript entry point: closure .js stubs get star exports only" {
  for target in nodejs typescript; do
    rm -f "$SRC/public-api.js"
    # protoc's closure/commonjs output carries no `export ` lines, so nothing to disambiguate
    printf 'goog.exportSymbol("proto.ondewo.nlu.DetectIntentRequest", null, global);\n' \
      > "$SRC/api/ondewo/nlu/session_pb.js"

    run_entry_point "$target" .js
    [ "$status" -eq 0 ]

    grep -Fq "export * from './api/ondewo/nlu/session_pb';" "$SRC/public-api.js"
    run grep -c '^export {' "$SRC/public-api.js"
    [ "$output" = "0" ]
  done
}
