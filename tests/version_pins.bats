#!/usr/bin/env bats
# The version-pin guard (tests/check-version-pins.sh): the Makefile, every Dockerfile ARG default
# and the hand-maintained manifests (python/requirements.txt, the rust Cargo.toml files, the go
# module template, the node package.json files) must agree. Each drift case runs the guard over a
# sandbox copy with ONE value changed, so the guard is shown to catch it - a guard that never fails
# proves nothing.

load 'helpers/setup'

setup() {
  common_setup
  command -v jq >/dev/null 2>&1 || skip "jq is required"
  COPY="$SANDBOX/repo"
  mkdir -p "$COPY"
  local item
  for item in Makefile Dockerfile.utils python java csharp php go rust js typescript angular nodejs cpp; do
    cp -R "$REPO_ROOT/$item" "$COPY/$item"
  done
}
teardown() { common_teardown; }

# drift <file> <perl substitution>
drift() {
  perl -i -pe "$2" "$COPY/$1"
}

@test "pins: the repository's Makefile, Dockerfiles and manifests agree" {
  run sh "$REPO_ROOT/tests/check-version-pins.sh"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "pins: the guard really reads the sandbox copy (unchanged copy passes)" {
  run sh "$REPO_ROOT/tests/check-version-pins.sh" "$COPY"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "pins: a Dockerfile ARG default that drifts from the Makefile is named" {
  drift java/Dockerfile 's/^ARG PROTOBUF_JAVA_VERSION=.*/ARG PROTOBUF_JAVA_VERSION=4.33.6/'
  run sh "$REPO_ROOT/tests/check-version-pins.sh" "$COPY"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"java/Dockerfile: ARG PROTOBUF_JAVA_VERSION=4.33.6"* ]]
}

@test "pins: a Makefile variable that drifts from every Dockerfile is named per Dockerfile" {
  drift Makefile 's/^PROTOC_VERSION=.*/PROTOC_VERSION=33.5/'
  run sh "$REPO_ROOT/tests/check-version-pins.sh" "$COPY"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"go/Dockerfile: ARG PROTOC_VERSION="* ]]
  [[ "$output" == *"angular/Dockerfile: ARG PROTOC_VERSION="* ]]
}

@test "pins: python/requirements.txt drifting from the grpcio pin is named" {
  drift python/requirements.txt 's/^grpcio-tools==.*/grpcio-tools==1.85.3/'
  run sh "$REPO_ROOT/tests/check-version-pins.sh" "$COPY"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"python/requirements.txt: grpcio-tools is '1.85.3'"* ]]
}

@test "pins: a rust crate floor drifting in only one of the two manifests is named" {
  drift rust/image-data/default-lib-files/prewarm-Cargo.toml 's/^prost = .*/prost = "0.14"/'
  run sh "$REPO_ROOT/tests/check-version-pins.sh" "$COPY"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"prewarm-Cargo.toml: prost is '0.14'"* ]]
}

@test "pins: the go module template drifting from GRPC_GO_VERSION is named" {
  drift go/image-data/default-lib-files/go.mod.template 's|(google\.golang\.org/grpc[[:space:]]+)v[^[:space:]]+|${1}v1.83.2|'
  run sh "$REPO_ROOT/tests/check-version-pins.sh" "$COPY"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"go.mod.template: google.golang.org/grpc is 'v1.83.2'"* ]]
}

@test "pins: a node manifest on another grpc-web than the generator plugin is named" {
  drift js/image-data/default-lib-files/package.json 's/"grpc-web": "[^"]*"/"grpc-web": "^1.5.0"/'
  drift angular/image-data/package.json 's/"grpc-web": "2[^"]*"/"grpc-web": "^1.5.0"/'
  run sh "$REPO_ROOT/tests/check-version-pins.sh" "$COPY"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"js/image-data/default-lib-files/package.json: grpc-web is '^1.5.0'"* ]]
  [[ "$output" == *"angular/image-data/package.json: grpc-web is '^1.5.0'"* ]]
}

@test "pins: the nodejs generator plugins drifting from the Makefile are named" {
  drift nodejs/image-data/package.json 's/"grpc-tools": "[^"]*"/"grpc-tools": "^1.13.1"/'
  run sh "$REPO_ROOT/tests/check-version-pins.sh" "$COPY"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nodejs/image-data/package.json: grpc-tools is '^1.13.1'"* ]]
}

@test "pins: a runtime off the protoc release line fails even when Makefile and Dockerfile agree" {
  drift Makefile 's/^GOOGLE_PROTOBUF_PHP_VERSION=.*/GOOGLE_PROTOBUF_PHP_VERSION=4.33.6/'
  drift php/Dockerfile 's/^ARG GOOGLE_PROTOBUF_PHP_VERSION=.*/ARG GOOGLE_PROTOBUF_PHP_VERSION=4.33.6/'
  run sh "$REPO_ROOT/tests/check-version-pins.sh" "$COPY"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GOOGLE_PROTOBUF_PHP_VERSION line is '4.33'"* ]]
}

@test "pins: a missing Makefile pin is reported as such" {
  drift Makefile 's/^PYTHON_GRPCIO_VERSION=.*//'
  run sh "$REPO_ROOT/tests/check-version-pins.sh" "$COPY"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Makefile: PYTHON_GRPCIO_VERSION is not set"* ]]
}
