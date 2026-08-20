#!/usr/bin/env bats
# Unit tests for angular/image-data/generate-public-api.sh, the barrel generator
# shared by make-lib-entry-point.sh (the public-api.ts that ng build compiles) and
# compile-proto-2-angular.sh (the copy shipped in npm/).
#
# Protos in different packages may legitimately declare the same top-level symbol --
# ondewo.nlu and ondewo.s2t both declare ReasoningEffort -- and a name reachable
# through two `export *` lines makes tsc fail the library build with TS2308.

load 'helpers/setup'

setup() {
  common_setup
  GEN="$REPO_ROOT/angular/image-data/generate-public-api.sh"
  SRC="$SANDBOX/src"
  OUT_FILE="$SRC/public-api.ts"
  mkdir -p "$SRC/api/ondewo/nlu" "$SRC/api/ondewo/s2t"
  : > "$OUT_FILE"
}
teardown() { common_teardown; }

@test "generate-public-api: star-exports every stub" {
  printf 'export class DetectIntentRequest {}\n' > "$SRC/api/ondewo/nlu/session.pb.ts"
  printf 'export class TranscribeRequest {}\n'   > "$SRC/api/ondewo/s2t/speech-to-text.pb.ts"

  run bash "$GEN" "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]

  grep -Fq "export * from './api/ondewo/nlu/session.pb';" "$OUT_FILE"
  grep -Fq "export * from './api/ondewo/s2t/speech-to-text.pb';" "$OUT_FILE"
}

@test "generate-public-api: emits no explicit re-export when nothing collides" {
  printf 'export class DetectIntentRequest {}\n' > "$SRC/api/ondewo/nlu/session.pb.ts"
  printf 'export class TranscribeRequest {}\n'   > "$SRC/api/ondewo/s2t/speech-to-text.pb.ts"

  run bash "$GEN" "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]

  run grep -c '^export {' "$OUT_FILE"
  [ "$output" = "0" ]
}

@test "generate-public-api: disambiguates a symbol declared by two stubs (TS2308)" {
  printf 'export enum ReasoningEffort {}\nexport class DetectIntentRequest {}\n' \
    > "$SRC/api/ondewo/nlu/session.pb.ts"
  printf 'export enum ReasoningEffort {}\nexport class TranscribeRequest {}\n' \
    > "$SRC/api/ondewo/s2t/speech-to-text.pb.ts"

  run bash "$GEN" "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]

  # bound to the first declaring stub in sorted order, and emitted exactly once
  grep -Fq "export { ReasoningEffort } from './api/ondewo/nlu/session.pb';" "$OUT_FILE"
  run grep -c "^export { ReasoningEffort }" "$OUT_FILE"
  [ "$output" = "1" ]

  # the star exports are kept, so non-colliding symbols stay reachable
  grep -Fq "export * from './api/ondewo/s2t/speech-to-text.pb';" "$OUT_FILE"
}

@test "generate-public-api: a name declared twice within one stub is not a collision" {
  # the generator emits `export class X` and `export module X` for the same message
  printf 'export class DetectIntentRequest {}\nexport module DetectIntentRequest {}\n' \
    > "$SRC/api/ondewo/nlu/session.pb.ts"
  printf 'export class TranscribeRequest {}\n' > "$SRC/api/ondewo/s2t/speech-to-text.pb.ts"

  run bash "$GEN" "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]

  run grep -c '^export {' "$OUT_FILE"
  [ "$output" = "0" ]
}

@test "generate-public-api: star-exports a hand-written auth barrel when one exists" {
  # Hand-written sources are not emitted by the compiler, so without this line `auth/` is
  # compiled but never bundled and no consumer can import a symbol from it.
  printf 'export class DetectIntentRequest {}\n' > "$SRC/api/ondewo/nlu/session.pb.ts"
  mkdir -p "$SRC/auth"
  printf 'export { KeycloakTokenProvider } from "./keycloak-token-provider";\n' > "$SRC/auth/index.ts"

  run bash "$GEN" "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]

  grep -Fq "export * from './auth';" "$OUT_FILE"
  run grep -c "export \* from './auth';" "$OUT_FILE"
  [ "$output" = "1" ]

  # the generated stubs are still star-exported
  grep -Fq "export * from './api/ondewo/nlu/session.pb';" "$OUT_FILE"
}

@test "generate-public-api: honours a barrel prefix for the copy written one level up" {
  # The entry file ng build compiles sits beside auth/; the copy written to the output
  # volume sits one level above the mounted input directory that holds it.
  printf 'export class DetectIntentRequest {}\n' > "$SRC/api/ondewo/nlu/session.pb.ts"
  mkdir -p "$SRC/auth"
  printf 'export { KeycloakTokenProvider } from "./keycloak-token-provider";\n' > "$SRC/auth/index.ts"

  run bash "$GEN" "$SRC" "$OUT_FILE" "./src"
  [ "$status" -eq 0 ]

  grep -Fq "export * from './src/auth';" "$OUT_FILE"
  run grep -c "export \* from './auth';" "$OUT_FILE"
  [ "$output" = "0" ]
}

@test "generate-public-api: omits the auth export for a client without an auth barrel" {
  printf 'export class DetectIntentRequest {}\n' > "$SRC/api/ondewo/nlu/session.pb.ts"

  run bash "$GEN" "$SRC" "$OUT_FILE"
  [ "$status" -eq 0 ]

  run grep -c "\./auth" "$OUT_FILE"
  [ "$output" = "0" ]
}

@test "generate-public-api: requires both arguments" {
  run bash "$GEN" "$SRC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}
