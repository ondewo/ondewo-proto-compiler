#!/usr/bin/env bats
# End-to-end tests for the four in-container orchestrator scripts
# (compile-proto-2-{angular,js,nodejs,typescript}.sh) run on the HOST: the
# container paths (/image-data, /input-volume, /output-volume) are overridden
# via the env knobs the scripts expose, and the toolchain (protoc,
# grpc_tools_node_protoc, npm) is PATH-mocked. The protoc mocks materialise
# dummy stub files per *_out flag, so the full pipeline — stub generation,
# entry-point creation, lib packaging, copy-back to the output volume — is
# exercised without Docker or a real toolchain.

load 'helpers/setup'

setup() {
  common_setup
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  export NPM_MOCK_LOG="$SANDBOX/npm.log"
  IN="$SANDBOX/input"; OUT="$SANDBOX/output"
  mkdir -p "$IN/protos/library" "$OUT"
  printf 'syntax = "proto3";\nimport "google/protobuf/empty.proto";\nmessage T {}\n' \
    > "$IN/protos/library/test.proto"
}
teardown() { common_teardown; }

# stage <lang>: copy the language's image-data into the sandbox (so nothing is
# written into the repo tree), cd there (scripts invoke their siblings as ./x.sh)
# and point the container-path env knobs at the sandbox.
stage() {
  cp -r "$REPO_ROOT/$1/image-data" "$SANDBOX/image-data"
  cd "$SANDBOX/image-data"
  export IMAGE_DATA_DIRECTORY="$SANDBOX/image-data"
  export INPUT_VOLUME_FS="$IN"
  export OUTPUT_VOLUME_FS="$OUT"
}

@test "e2e nodejs: full pipeline packages stubs + package.json into the output volume" {
  printf '{"name":"fixture","version":"0.0.1"}\n' > "$IN/package.json"
  stage nodejs
  run bash ./compile-proto-2-nodejs.sh protos library
  [ "$status" -eq 0 ]
  [ -f "$OUT/api/mock_pb.d.ts" ]
  [ -f "$OUT/package.json" ]
  [ -f "$OUT/public-api.d.ts" ]
}

@test "e2e nodejs: missing package.json in the input volume fails loudly" {
  stage nodejs
  run bash ./compile-proto-2-nodejs.sh protos library
  [ "$status" -ne 0 ]
  [[ "$output" == *"package.json"* ]]
}

@test "e2e typescript: full pipeline packages stubs into the output volume" {
  printf '{"name":"fixture","version":"0.0.1"}\n' > "$IN/package.json"
  stage typescript
  run bash ./compile-proto-2-typescript.sh protos library
  [ "$status" -eq 0 ]
  [ -f "$OUT/api/mock_grpc_web_pb.d.ts" ]
  [ -f "$OUT/package.json" ]
}

@test "e2e angular: full pipeline produces api stubs, public-api.ts and the npm folder" {
  printf '{"name":"fixture","version":"0.0.1"}\n' > "$IN/package.json"
  printf '# npm readme\n'    > "$IN/README.md"
  mkdir -p "$IN/.github"
  printf '# github readme\n' > "$IN/.github/README.md"
  printf '# release\n'       > "$IN/RELEASE.md"
  stage angular
  run bash ./compile-proto-2-angular.sh protos
  [ "$status" -eq 0 ]
  [ -f "$OUT/api/mock_pb.ts" ]
  [ -f "$OUT/npm/public-api.ts" ]
  run grep -Fq "export * from './api/mock_pb';" "$OUT/public-api.ts"
  [ "$status" -eq 0 ]
}

@test "e2e angular: a missing required input file (README.md) fails loudly" {
  printf '{"name":"fixture","version":"0.0.1"}\n' > "$IN/package.json"
  stage angular
  run bash ./compile-proto-2-angular.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"README.md"* ]]
}

@test "e2e js: full pipeline bundles the webpack output into the output volume" {
  # the js target runs the project-local webpack binary; provide a fake one that
  # emulates a bundle landing in ./lib (npm install is already PATH-mocked)
  mkdir -p "$IN/node_modules/.bin"
  printf '#!/usr/bin/env bash\nmkdir -p lib && : > lib/mock-bundle.js\n' \
    > "$IN/node_modules/.bin/webpack"
  chmod +x "$IN/node_modules/.bin/webpack"
  stage js
  export TEMP_SRC_DIRECTORY="$SANDBOX/temp_src"
  run bash ./compile-proto-2-js.sh mylibrary protos
  [ "$status" -eq 0 ]
  [ -f "$OUT/mock-bundle.js" ]
}

@test "e2e js: input volume without protos fails loudly" {
  mkdir -p "$IN/node_modules/.bin"
  rm -rf "$IN/protos"
  stage js
  export TEMP_SRC_DIRECTORY="$SANDBOX/temp_src"
  run bash ./compile-proto-2-js.sh mylibrary protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files"* ]]
}
