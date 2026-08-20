#!/usr/bin/env bats
# Unit tests for the nodejs / typescript append-auth-exports.sh scripts.
#
# Those two targets keep hand-written sources at the OUTPUT volume root, beside the
# generated barrels, rather than inside the mounted input directory the way angular does,
# so their auth re-export is appended after the output copy instead of by the barrel
# generator (see public_api_barrel.bats for the angular path).

load 'helpers/setup'

setup() {
  common_setup
  OUT="$SANDBOX/out"
  mkdir -p "$OUT/auth"
  printf "export * from './api/ondewo/nlu/agent_pb.d';\n" > "$OUT/public-api.d.ts"
  printf "export * from './api/ondewo/nlu/agent_pb';\n"   > "$OUT/public-api.js"
}
teardown() { common_teardown; }

run_append() {
  run bash "$REPO_ROOT/$1/image-data/append-auth-exports.sh" "$OUT"
}

@test "append-auth-exports: re-exports the auth module from both barrels" {
  for target in nodejs typescript; do
    printf "export * from './api/ondewo/nlu/agent_pb.d';\n" > "$OUT/public-api.d.ts"
    printf "export * from './api/ondewo/nlu/agent_pb';\n"   > "$OUT/public-api.js"
    : > "$OUT/auth/offlineTokenProvider.ts"

    run_append "$target"
    [ "$status" -eq 0 ]

    grep -Fq "export * from './auth/offlineTokenProvider';" "$OUT/public-api.d.ts"
    grep -Fq "export * from './auth/offlineTokenProvider';" "$OUT/public-api.js"
    # the generated stub exports are kept
    grep -Fq "export * from './api/ondewo/nlu/agent_pb.d';" "$OUT/public-api.d.ts"
  done
}

@test "append-auth-exports: collapses the .ts/.js/.d.ts spellings of one module" {
  : > "$OUT/auth/offlineTokenProvider.ts"
  : > "$OUT/auth/offlineTokenProvider.js"
  : > "$OUT/auth/offlineTokenProvider.d.ts"

  run_append nodejs
  [ "$status" -eq 0 ]

  run grep -c "auth/offlineTokenProvider" "$OUT/public-api.d.ts"
  [ "$output" = "1" ]
}

@test "append-auth-exports: never re-exports a spec or test file" {
  : > "$OUT/auth/offlineTokenProvider.ts"
  : > "$OUT/auth/offlineTokenProvider.spec.ts"
  : > "$OUT/auth/offlineTokenProvider.test.ts"

  run_append typescript
  [ "$status" -eq 0 ]

  run grep -c "spec\|test" "$OUT/public-api.d.ts"
  [ "$output" = "0" ]
}

@test "append-auth-exports: is idempotent across reruns" {
  : > "$OUT/auth/offlineTokenProvider.ts"

  run_append nodejs
  [ "$status" -eq 0 ]
  run_append nodejs
  [ "$status" -eq 0 ]
  run_append nodejs
  [ "$status" -eq 0 ]

  run grep -c "auth/offlineTokenProvider" "$OUT/public-api.js"
  [ "$output" = "1" ]
}

@test "append-auth-exports: a client without auth/ is untouched" {
  rmdir "$OUT/auth"

  run_append typescript
  [ "$status" -eq 0 ]

  run grep -c "auth" "$OUT/public-api.js"
  [ "$output" = "0" ]
}

@test "append-auth-exports: requires the output root argument" {
  run bash "$REPO_ROOT/nodejs/image-data/append-auth-exports.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}

@test "append-auth-exports: nodejs and typescript ship the same script" {
  run diff "$REPO_ROOT/nodejs/image-data/append-auth-exports.sh" \
           "$REPO_ROOT/typescript/image-data/append-auth-exports.sh"
  [ "$status" -eq 0 ]
}
