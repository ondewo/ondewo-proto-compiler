#!/usr/bin/env bats
# Fast (no Docker, no network) guards for the angular target's backward-compatibility contract.
# The full proof is the integration harness tests/angular-compat/ (`make test_angular_compat`):
# it installs the compiled library into a real app on every ANGULAR_COMPAT_VERSIONS entry, runs an
# AOT `ng build` and a runtime check there. This file pins what that proof relies on:
#
#   * the linker gate (declaration-gate.mjs) - a library built by Angular N links on Angular M < N
#     iff every ɵɵngDeclare* `minVersion` is <= M; the `version` stamp is irrelevant;
#   * the image builds with the NEWEST supported major, the clients' peer range starts at the
#     OLDEST, and the compat matrix has no gap in between.

load 'helpers/setup'

setup() {
  common_setup
  command -v node >/dev/null 2>&1 || skip "node is required"
  GATE="$REPO_ROOT/tests/angular-compat/consumer/declaration-gate.mjs"
  COMPAT_VERSIONS="$(sed -n 's/^ANGULAR_COMPAT_VERSIONS=//p' "$REPO_ROOT/Makefile")"
  OLDEST="$(printf '%s\n' $COMPAT_VERSIONS | cut -d. -f1 | sort -n | head -n 1)"
  NEWEST="$(printf '%s\n' $COMPAT_VERSIONS | cut -d. -f1 | sort -n | tail -n 1)"
}

teardown() { common_teardown; }

# node -p over a package.json: dep_range <file> <section> <name>
dep_range() {
  node -p "(require('$1')['$2'] || {})['$3'] || ''"
}

@test "gate: an Angular 20 bundle (one-line declarations) links on 20.0.0" {
  printf '%s\n' 'static { this.ɵfac = i0.ɵɵngDeclareFactory({ minVersion: "12.0.0", version: "20.3.35", ngImport: i0 }); }' \
    'i0.ɵɵngDeclareNgModule({ minVersion: "14.0.0", version: "20.3.35", ngImport: i0 });' > "$SANDBOX/b.mjs"
  run node "$GATE" "$SANDBOX/b.mjs" 20.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 partial declarations (built by Angular 20.3.35) link on Angular 20.0.0"* ]]
}

@test "gate: an Angular 22 bundle (multi-line declarations) still links on 20.0.0" {
  printf '%s\n' 'this.ɵfac = i0.ɵɵngDeclareFactory({' '	minVersion: "12.0.0",' '	version: "22.2.6",' '	ngImport: i0' '});' \
    'this.ɵprov = i0.ɵɵngDeclareInjectable({' '	minVersion: "12.0.0",' '	version: "22.2.6",' '});' > "$SANDBOX/b.mjs"
  run node "$GATE" "$SANDBOX/b.mjs" 20.0.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 partial declarations (built by Angular 22.2.6)"* ]]
}

@test "gate: a declaration whose minVersion is newer than the consumer fails, and names it" {
  printf '%s\n' 'i0.ɵɵngDeclareComponent({ minVersion: "21.1.0", version: "22.2.6", ngImport: i0 });' > "$SANDBOX/b.mjs"
  run node "$GATE" "$SANDBOX/b.mjs" 20.3.35
  [ "$status" -eq 1 ]
  [[ "$output" == *"need Angular >= 21.1.0"* ]]
  run node "$GATE" "$SANDBOX/b.mjs" 21.1.0
  [ "$status" -eq 0 ]
}

@test "gate: a prerelease consumer compares by its release version" {
  printf '%s\n' 'i0.ɵɵngDeclareFactory({ minVersion: "22.0.0", version: "22.2.6", ngImport: i0 });' > "$SANDBOX/b.mjs"
  run node "$GATE" "$SANDBOX/b.mjs" 22.3.0-rc.0
  [ "$status" -eq 0 ]
}

@test "gate: a bundle without partial declarations fails instead of passing vacuously" {
  printf '%s\n' 'export class Foo {}' > "$SANDBOX/b.mjs"
  run node "$GATE" "$SANDBOX/b.mjs" 22.0.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"no ɵɵngDeclare* partial declarations"* ]]
}

@test "matrix: ANGULAR_COMPAT_VERSIONS covers every major from the oldest to the newest, and the floor as .0.0" {
  [ -n "$COMPAT_VERSIONS" ]
  major=$OLDEST
  while [ "$major" -le "$NEWEST" ]; do
    printf '%s\n' $COMPAT_VERSIONS | cut -d. -f1 | grep -qx "$major" || { echo "major $major untested"; return 1; }
    major=$((major + 1))
  done
  printf '%s\n' $COMPAT_VERSIONS | grep -qx "$OLDEST.0.0"
}

@test "toolchain: the image builds with the NEWEST supported Angular, every package on the same major" {
  pkg="$REPO_ROOT/angular/image-data/package.json"
  for dep in @angular-devkit/build-angular @angular/cli @angular/common @angular/compiler \
    @angular/compiler-cli @angular/core ng-packagr; do
    range="$(dep_range "$pkg" devDependencies "$dep")"
    [ "$range" = ">=$NEWEST.0.0 <$((NEWEST + 1)).0.0" ] || { echo "$dep: '$range'"; return 1; }
  done
}

@test "toolchain: typescript is bounded above (a new TS major must be an explicit upgrade)" {
  range="$(dep_range "$REPO_ROOT/angular/image-data/package.json" devDependencies typescript)"
  [[ "$range" == *"<"* ]] || { echo "typescript: '$range'"; return 1; }
}

@test "peers: example and compat fixture accept exactly the OLDEST through the NEWEST major" {
  for pkg in "$REPO_ROOT/angular/example/package.json" "$REPO_ROOT/tests/angular-compat/fixture-client/package.json"; do
    for dep in @angular/core @angular/common; do
      range="$(dep_range "$pkg" peerDependencies "$dep")"
      [ "$range" = ">=$OLDEST.0.0 <$((NEWEST + 1)).0.0" ] || { echo "$pkg $dep: '$range'"; return 1; }
    done
  done
}

@test "peers: the default lib tsconfig carries no option the newest toolchain's TypeScript rejects" {
  cfg="$REPO_ROOT/angular/image-data/default-lib-files/tsconfig.json"
  # TS 6.0 errors (TS5101/TS5107) on these; moduleResolution node10 cannot see @angular/* exports.
  ! grep -Eq '"(baseUrl|downlevelIteration)"' "$cfg"
  ! grep -Eq '"moduleResolution": *"(node|node10)"' "$cfg"
}

@test "harness: run-compat.sh without a package directory exits 2 before calling docker" {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  run sh "$REPO_ROOT/tests/angular-compat/run-compat.sh" "$SANDBOX/missing"
  [ "$status" -eq 2 ]
  [[ "$output" == *"holds no package.json"* ]]
  [ ! -s "$DOCKER_MOCK_LOG" ]
}

@test "harness: run-compat.sh defaults to the Makefile's ANGULAR_COMPAT_VERSIONS and runs each one" {
  mkdir -p "$SANDBOX/pkg" "$SANDBOX/work"
  echo '{"name":"x"}' > "$SANDBOX/pkg/package.json"
  : > "$SANDBOX/work/x-0.0.0.tgz"
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log" ANGULAR_COMPAT_WORK_DIR="$SANDBOX/work"
  unset ANGULAR_COMPAT_VERSIONS
  run sh "$REPO_ROOT/tests/angular-compat/run-compat.sh" "$SANDBOX/pkg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"library works on Angular $COMPAT_VERSIONS"* ]]
  for v in $COMPAT_VERSIONS; do
    grep -q "check.sh $v /work/x-0.0.0.tgz" "$DOCKER_MOCK_LOG" || { echo "no run for $v"; return 1; }
  done
}

@test "harness: a failing version fails the run and is named, the others still run" {
  mkdir -p "$SANDBOX/pkg" "$SANDBOX/work" "$SANDBOX/bin"
  echo '{"name":"x"}' > "$SANDBOX/pkg/package.json"
  : > "$SANDBOX/work/x-0.0.0.tgz"
  printf '#!/bin/sh\necho "docker $*" >> "%s"\ncase "$*" in *"check.sh 21 "*) exit 1 ;; esac\nexit 0\n' "$SANDBOX/docker.log" > "$SANDBOX/bin/docker"
  chmod +x "$SANDBOX/bin/docker"
  PATH="$SANDBOX/bin:$PATH" ANGULAR_COMPAT_WORK_DIR="$SANDBOX/work" \
    run sh "$REPO_ROOT/tests/angular-compat/run-compat.sh" "$SANDBOX/pkg" 20 21 22
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed for: 21"* ]]
  grep -q "check.sh 22 " "$SANDBOX/docker.log"
}

@test "toolchain: @ngx-grpc is capped at ~3.1.2 and grpc-web is the exact GRPC_WEB_VERSION, overriding @ngx-grpc's ^1.2.1 peer" {
  local pkg="$REPO_ROOT/angular/image-data/package.json" name want
  want="$(sed -n 's/^GRPC_WEB_VERSION=//p' "$REPO_ROOT/Makefile")"
  # an open `>=3.1.2` floats to whatever @ngx-grpc publishes next (5.0.0 today) at image build
  for name in common core grpc-web-client protoc-gen-ng well-known-types; do
    [ "$(dep_range "$pkg" devDependencies "@ngx-grpc/$name")" = "~3.1.2" ]
  done
  # npm `overrides` only accept a "$grpc-web" reference to a direct dependency of the SAME exact spec
  [ "$(dep_range "$pkg" devDependencies grpc-web)" = "$want" ]
  [ "$(node -p "require('$pkg').overrides['grpc-web']")" = '$grpc-web' ]
  # @ngx-grpc/common and well-known-types peer google-protobuf ^3.10.0: stay on 3.21.x
  [ "$(dep_range "$pkg" devDependencies google-protobuf)" = "~3.21.4" ]
}
