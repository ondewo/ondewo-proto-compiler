#!/usr/bin/env bats
# Behavioural coverage for the `rust/` proto-compiler target, driven on the HOST.
#
# The three real image-data scripts (compile-proto-2-rust.sh, compile-proto-2-stubs.sh,
# compile-stubs-2-lib.sh) plus make-lib-entry-point.sh are executed for real; only the
# container paths are redirected (IMAGE_DATA_DIRECTORY / INPUT_VOLUME_FS /
# OUTPUT_VOLUME_FS / TEMP_SRC_DIRECTORY / CRATE_DIRECTORY / DIST_DIRECTORY /
# CARGO_REGISTRY_HOME) and the toolchain (protoc, cargo) is PATH-mocked. No Docker, no
# network, no rust toolchain.
#
# What is pinned here, target-specific:
#   * the mounted input volume is copied to the private temp dir and never mutated;
#   * protoc runs EXACTLY ONCE, with --prost_out before --tonic_out into the SAME
#     directory (splitting or reordering silently drops every gRPC client);
#   * google/protobuf/** is never recompiled (it stays mapped to ::prost_types);
#   * src/api is entirely generated - it is never seeded from the input volume and is
#     wiped in the output volume, while hand-written modules beside it survive;
#   * the crate manifest template comes from the input volume when present, else from
#     the image default, and the packaged <name>-<version>.crate is named after it;
#   * the offline dependency pre-flight rejects anything the image did not pre-warm,
#     before cargo is ever invoked;
#   * an ambient CARGO_TARGET_DIR cannot redirect the build or the artifact lookup.

load 'helpers/setup'

# NOTE: none of these names may start with one of the prefixes common_setup's
# scrub_toolchain_env() sweeps (CARGO_/RUST/GO/PROTOC/ONDEWO_/...), or they are unset
# out from under the test.
TARGET_IMAGE_DATA="rust/image-data"
DEFAULT_MANIFEST="rust/image-data/default-lib-files/Cargo.toml"
PREWARM_MANIFEST="rust/image-data/default-lib-files/prewarm-Cargo.toml"

# Every `<name> = ...` key of a manifest's [dependencies] table. Mirrors the extraction
# compile-stubs-2-lib.sh does, so the fake registry cache below is primed with exactly
# the names the real pre-flight will look for.
manifest_dependencies() {
  sed -n '/^\[dependencies\]/,$p' "$1" \
    | sed -n 's|^\([A-Za-z0-9_-][A-Za-z0-9_-]*\)[[:space:]]*=.*|\1|p'
}

# A quoted key of the [package] table (the sed range stops at the next section header).
manifest_package_field() {
  sed -n '/^\[package\]/,/^\[/p' "$2" \
    | sed -n "s|^$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*|\1|p" \
    | head -1
}

# Fake the image's pre-warmed cargo registry cache. Primed from the PRE-WARM manifest,
# which is the image's own promise of what is downloadable offline - so a dependency
# added to the shipped default manifest without being pre-warmed fails every case here,
# exactly as it would fail in the image.
prime_cargo_cache() {
  local cache="$CARGO_REGISTRY_HOME/registry/cache/mock-registry" dep
  mkdir -p "$cache"
  for dep in $(manifest_dependencies "$REPO_ROOT/$PREWARM_MANIFEST"); do
    : > "$cache/$dep-0.0.1.crate"
  done
}

# The .proto positional arguments protoc was handed, one per line, sorted.
protoc_input_protos() {
  tr ' ' '\n' < "$PROTOC_MOCK_LOG" | grep '\.proto$' | sort
}

# Install a purpose-built `protoc` ahead of the shared PATH mock for ONE test: the
# shared mock always materialises the full prost + tonic + prost-crate output, so a
# run in which ONE of the three plugins silently did not fire needs its own. The
# script body is read from stdin, so the caller writes it as a heredoc; it keeps
# appending to the same argv log, which is what makes "protoc really was invoked and
# it is the post-condition that failed" assertable instead of indistinguishable from
# an earlier guard.
shadow_protoc() {
  mkdir -p "$SANDBOX/shadow-bin"
  cat > "$SANDBOX/shadow-bin/protoc"
  chmod +x "$SANDBOX/shadow-bin/protoc"
  PATH="$SANDBOX/shadow-bin:$PATH"
  export PATH
}

# Same for `cargo`: the shared mock always leaves a <name>-<version>.crate in
# $CARGO_TARGET_DIR/package, so a cargo that exits 0 without producing the artifact
# the copy-back collects needs its own.
shadow_cargo() {
  mkdir -p "$SANDBOX/shadow-bin"
  cat > "$SANDBOX/shadow-bin/cargo"
  chmod +x "$SANDBOX/shadow-bin/cargo"
  PATH="$SANDBOX/shadow-bin:$PATH"
  export PATH
}

setup() {
  common_setup

  # Mock knobs must be exported AFTER common_setup (it scrubs the toolchain namespaces).
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  export CARGO_MOCK_LOG="$SANDBOX/cargo.log"

  IN="$SANDBOX/input"
  OUT="$SANDBOX/output"
  IMG="$SANDBOX/image-data"
  CRATE="$IMG/crate"

  mkdir -p "$IN/protos/library" "$IN/protos/dependency" "$OUT"
  printf 'syntax = "proto3";\npackage library;\nimport "dependency/myimport.proto";\nmessage Test { dependency.MyImport my_import = 1; }\nservice SimpleService { rpc SendTest (Test) returns (Test); }\n' \
    > "$IN/protos/library/test.proto"
  printf 'syntax = "proto3";\npackage dependency;\nmessage MyImport { string name = 1; }\n' \
    > "$IN/protos/dependency/myimport.proto"

  # Run against a sandbox copy of image-data so nothing is ever written into the repo.
  cp -r "$REPO_ROOT/$TARGET_IMAGE_DATA" "$IMG"

  export IMAGE_DATA_DIRECTORY="$IMG"
  export INPUT_VOLUME_FS="$IN"
  export OUTPUT_VOLUME_FS="$OUT"

  # Never let the HOST decide whether the offline pre-flight runs: without this a machine
  # that happens to have /usr/local/cargo would exercise a different code path.
  export CARGO_REGISTRY_HOME="$SANDBOX/cargo-home"
  prime_cargo_cache

  # The orchestrator invokes its siblings as ./x.sh, so it must run from image-data.
  cd "$IMG"
}

teardown() {
  cd "$REPO_ROOT" || true
  common_teardown
}

run_rust() { run bash ./compile-proto-2-rust.sh "$@"; }

# ----------------------------------------------------------------- orchestrator e2e

@test "rust e2e: produces the documented output-volume layout and packages the crate" {
  run_rust protos
  [ "$status" -eq 0 ]

  # crate sources + barrel + generated module tree
  [ -f "$OUT/Cargo.toml" ]
  [ -f "$OUT/src/lib.rs" ]
  [ -f "$OUT/src/api/mod.rs" ]                  # protoc-gen-prost-crate include file
  [ -f "$OUT/src/api/mock.package.rs" ]         # protoc-gen-prost, one per proto package
  [ -f "$OUT/src/api/mock.package.tonic.rs" ]   # protoc-gen-tonic, per service package

  # the packaged tarball, named after the manifest the build actually used
  name="$(manifest_package_field name "$REPO_ROOT/$DEFAULT_MANIFEST")"
  version="$(manifest_package_field version "$REPO_ROOT/$DEFAULT_MANIFEST")"
  [ -f "$OUT/crate-dist/$name-$version.crate" ]

  # the real package build ran (this is what proves the generated code compiles)
  grep -Fq "cargo build --release --offline" "$CARGO_MOCK_LOG"
  grep -Fq "cargo package --offline --no-verify --allow-dirty" "$CARGO_MOCK_LOG"
}

@test "rust e2e: the mounted input volume is never mutated" {
  cp -r "$IN" "$SANDBOX/input-snapshot"

  run_rust protos
  [ "$status" -eq 0 ]

  run diff -r "$SANDBOX/input-snapshot" "$IN"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "rust e2e: compilation happens in the private temp copy, never in the mount" {
  run_rust protos
  [ "$status" -eq 0 ]

  # the input volume was copied to the default TEMP_SRC_DIRECTORY ($IMAGE_DATA/src)
  [ -f "$IMG/src/protos/library/test.proto" ]

  line="$(head -n 1 "$PROTOC_MOCK_LOG")"
  [[ "$line" == *" -I $IMG/src/protos "* ]]
  # nothing protoc saw points back at the mount
  [[ "$line" != *"$IN"* ]]
}

@test "rust e2e: TEMP_SRC/CRATE/DIST overrides are honoured and the crate is assembled there" {
  export TEMP_SRC_DIRECTORY="$SANDBOX/tmp-src"
  export CRATE_DIRECTORY="$SANDBOX/the-crate"
  export DIST_DIRECTORY="$SANDBOX/the-dist"

  run_rust protos
  [ "$status" -eq 0 ]

  [ -f "$SANDBOX/tmp-src/protos/library/test.proto" ]
  [ -f "$SANDBOX/the-crate/Cargo.toml" ]
  [ -f "$SANDBOX/the-crate/src/lib.rs" ]
  [ -f "$SANDBOX/the-crate/src/api/mod.rs" ]
  run bash -c "find '$SANDBOX/the-dist' -name '*.crate' | grep -c ."
  [ "$output" = "1" ]
}

@test "rust e2e: a Cargo.toml in the input volume is the gen_crate template and names the artifact" {
  printf '[package]\nname = "ondewo-nlu-client"\nversion = "7.2.1"\nedition = "2021"\n\n[dependencies]\nprost = "0.14"\n' \
    > "$IN/Cargo.toml"

  run_rust protos
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARN: no Cargo.toml in the mounted input volume"* ]]

  # protoc got the client's manifest, resolved to an absolute path, as gen_crate=
  grep -Fq "gen_crate=$IMG/src/Cargo.toml" "$PROTOC_MOCK_LOG"

  # ... and cargo (which reads the manifest from its CWD) named the tarball after it
  [ -f "$OUT/crate-dist/ondewo-nlu-client-7.2.1.crate" ]
  grep -Fq 'name = "ondewo-nlu-client"' "$OUT/Cargo.toml"
}

@test "rust e2e: no Cargo.toml in the input volume warns and falls back to the image default" {
  run_rust protos
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: no Cargo.toml in the mounted input volume"* ]]
  [[ "$output" == *"ondewo-proto-stubs"* ]]

  grep -Fq "gen_crate=$IMG/default-lib-files/Cargo.toml" "$PROTOC_MOCK_LOG"
}

@test "rust e2e: the image pre-warmed Cargo.lock is seeded into the crate and shipped" {
  mkdir -p "$IMG/prewarm"
  printf '# pre-warmed lockfile\n' > "$IMG/prewarm/Cargo.lock"

  run_rust protos
  [ "$status" -eq 0 ]
  [[ "$output" == *"seeding the pre-warmed lockfile"* ]]
  grep -Fq "# pre-warmed lockfile" "$OUT/Cargo.lock"
}

@test "rust e2e: without a pre-warmed lockfile no Cargo.lock is invented" {
  run_rust protos
  [ "$status" -eq 0 ]
  [ ! -f "$OUT/Cargo.lock" ]
}

# ------------------------------------------------------------ output-volume fallback

@test "rust output volume: a non-existent output volume falls back to <input>/lib" {
  export OUTPUT_VOLUME_FS="$SANDBOX/not-mounted"

  run_rust protos
  [ "$status" -eq 0 ]
  [[ "$output" == *"Destination volume not specified"* ]]

  [ ! -d "$SANDBOX/not-mounted" ]
  [ -f "$IN/lib/Cargo.toml" ]
  [ -f "$IN/lib/src/lib.rs" ]
  [ -f "$IN/lib/src/api/mod.rs" ]
  run bash -c "find '$IN/lib/crate-dist' -name '*.crate' | grep -c ."
  [ "$output" = "1" ]
}

# --------------------------------------------------------------- stale-output wipe

@test "rust stale output: a stub for a since-deleted proto does not survive the re-run" {
  mkdir -p "$OUT/src/api" "$OUT/crate-dist"
  printf 'pub struct Ghost;\n' > "$OUT/src/api/deleted_package.rs"
  : > "$OUT/crate-dist/ondewo-proto-stubs-0.0.1.crate"

  run_rust protos
  [ "$status" -eq 0 ]

  [ ! -f "$OUT/src/api/deleted_package.rs" ]
  [ ! -f "$OUT/crate-dist/ondewo-proto-stubs-0.0.1.crate" ]
  # fresh output did land
  [ -f "$OUT/src/api/mod.rs" ]
  run bash -c "find '$OUT/crate-dist' -name '*.crate' | grep -c ."
  [ "$output" = "1" ]
}

@test "rust stale output: hand-written modules beside src/api survive the wipe" {
  mkdir -p "$OUT/src/auth"
  printf 'pub fn token() {}\n' > "$OUT/src/auth/mod.rs"
  printf 'pub fn helper() {}\n' > "$OUT/src/support.rs"

  run_rust protos
  [ "$status" -eq 0 ]

  grep -Fq "pub fn token() {}" "$OUT/src/auth/mod.rs"
  grep -Fq "pub fn helper() {}" "$OUT/src/support.rs"
}

@test "rust stale output: input and output on the SAME tree does not resurrect old stubs" {
  # a client mounting its repo root as both volumes: the previous run's src/api is inside
  # the input volume, so it is copied into the temp dir - it must still not come back.
  export OUTPUT_VOLUME_FS="$IN"

  run_rust protos
  [ "$status" -eq 0 ]
  printf 'pub struct Ghost;\n' > "$IN/src/api/deleted_package.rs"

  run_rust protos
  [ "$status" -eq 0 ]
  [ ! -f "$IN/src/api/deleted_package.rs" ]
  [ -f "$IN/src/api/mod.rs" ]
}

@test "rust crate assembly: src/api is never seeded from the input volume" {
  mkdir -p "$IN/src/api"
  printf 'pub struct Leftover;\n' > "$IN/src/api/leftover.rs"

  run_rust protos
  [ "$status" -eq 0 ]

  [ ! -f "$CRATE/src/api/leftover.rs" ]
  [ ! -f "$OUT/src/api/leftover.rs" ]
}

@test "rust crate assembly: a rust-toolchain.toml / .cargo config is not taken over" {
  printf '[toolchain]\nchannel = "nightly"\n' > "$IN/rust-toolchain.toml"
  mkdir -p "$IN/.cargo"
  printf '[source.crates-io]\nreplace-with = "vendored"\n' > "$IN/.cargo/config.toml"

  run_rust protos
  [ "$status" -eq 0 ]

  [ ! -e "$CRATE/rust-toolchain.toml" ]
  [ ! -e "$CRATE/.cargo" ]
  [ ! -e "$OUT/rust-toolchain.toml" ]
  [ ! -e "$OUT/.cargo" ]
}

# ------------------------------------------------------------------ argument handling

@test "rust args: no argument defaults the protos root to 'protos'" {
  run_rust
  [ "$status" -eq 0 ]
  line="$(head -n 1 "$PROTOC_MOCK_LOG")"
  [[ "$line" == *" -I $IMG/src/protos "* ]]
}

@test "rust args: an explicit relative protos dir is used as the protoc -I root" {
  mkdir -p "$IN/ondewo-nlu-api/ondewo"
  printf 'syntax = "proto3";\npackage ondewo.nlu;\nmessage Session {}\n' \
    > "$IN/ondewo-nlu-api/ondewo/session.proto"

  run_rust ondewo-nlu-api
  [ "$status" -eq 0 ]

  line="$(head -n 1 "$PROTOC_MOCK_LOG")"
  [[ "$line" == *" -I $IMG/src/ondewo-nlu-api "* ]]
  run protoc_input_protos
  [ "$output" = "ondewo/session.proto" ]
}

@test "rust args: the target subdir scopes compilation and still pulls in its imports" {
  mkdir -p "$IN/protos/other"
  printf 'syntax = "proto3";\npackage other;\nmessage Other {}\n' \
    > "$IN/protos/other/other.proto"

  run_rust protos library
  [ "$status" -eq 0 ]

  run protoc_input_protos
  echo "$output"
  # the entry proto plus its transitive import, and nothing from the sibling sub-tree
  [[ "$output" == *"library/test.proto"* ]]
  [[ "$output" == *"dependency/myimport.proto"* ]]
  [[ "$output" != *"other/other.proto"* ]]
}

@test "rust args: a missing protos root fails loudly and runs nothing" {
  run_rust no-such-dir
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found"* ]]
  [[ "$output" == *"no-such-dir"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$CARGO_MOCK_LOG" ]
}

@test "rust args: a missing target sub-directory fails loudly" {
  run_rust protos no-such-subdir
  [ "$status" -ne 0 ]
  [[ "$output" == *"target sub-directory 'no-such-subdir' does not exist"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "rust args: a missing input volume fails loudly before anything is copied" {
  export INPUT_VOLUME_FS="$SANDBOX/never-mounted"
  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"input volume"* ]]
  [[ "$output" == *"does not exist"* ]]
  [ ! -d "$IMG/src" ]
}

@test "rust args: an image without default-lib-files reports an incomplete image" {
  rm -rf "$IMG/default-lib-files"
  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"the image is incomplete"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "rust args: an image whose default-lib-files carries no Cargo.toml fails loudly" {
  # default-lib-files/ is present (so the image-completeness guard passes) but the
  # fallback manifest template inside it is gone: with no Cargo.toml in the input
  # volume either there is nothing to hand protoc as gen_crate=, and the run must
  # stop instead of letting protoc-gen-prost-crate fail on a missing template.
  rm -f "$IMG/default-lib-files/Cargo.toml"

  run_rust protos
  [ "$status" -ne 0 ]
  # the warning fired first (the input volume carries no manifest either) ...
  [[ "$output" == *"WARN: no Cargo.toml in the mounted input volume"* ]]
  # ... and then the image default turned out to be missing too
  [[ "$output" == *"ERROR: the crate manifest template"* ]]
  [[ "$output" == *"$IMG/default-lib-files/Cargo.toml' does not exist"* ]]

  # nothing downstream ran and nothing was written to the output volume
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$CARGO_MOCK_LOG" ]
  [ ! -d "$OUT/src" ]
  [ ! -f "$OUT/Cargo.toml" ]
}

# --------------------------------------------------------------- protoc invocation

@test "rust protoc: exactly ONE invocation, --prost_out before --tonic_out, same dir" {
  run_rust protos
  [ "$status" -eq 0 ]

  # protoc-gen-tonic writes into an insertion point of the file protoc-gen-prost wrote;
  # a second invocation or a swapped order silently drops every gRPC client.
  run bash -c "grep -c . '$PROTOC_MOCK_LOG'"
  [ "$output" = "1" ]

  line="$(head -n 1 "$PROTOC_MOCK_LOG")"
  [[ "$line" == *"--prost_out=$CRATE/src/api"*"--tonic_out=$CRATE/src/api"* ]]
}

@test "rust protoc: carries the three plugin outputs and the crate options" {
  run_rust protos
  [ "$status" -eq 0 ]

  line="$(head -n 1 "$PROTOC_MOCK_LOG")"
  [[ "$line" == *"--prost_opt=flat_output_dir"* ]]
  [[ "$line" == *"--tonic_opt=flat_output_dir"* ]]
  [[ "$line" == *"--prost-crate_out=$CRATE "* ]]
  [[ "$line" == *"--prost-crate_opt=flat_output_dir,no_features,include_file=src/api/mod.rs,gen_crate="* ]]
}

@test "rust protoc: google/protobuf well-known types are never recompiled" {
  # a vendored copy under the protos root AND an import of it: neither may reach protoc,
  # or the crate gets a second, duplicate `google.protobuf` module instead of ::prost_types
  mkdir -p "$IN/protos/google/protobuf"
  printf 'syntax = "proto3";\npackage google.protobuf;\nmessage Empty {}\n' \
    > "$IN/protos/google/protobuf/empty.proto"
  printf 'syntax = "proto3";\npackage library;\nimport "google/protobuf/empty.proto";\nmessage Test {}\n' \
    > "$IN/protos/library/test.proto"

  run_rust protos
  [ "$status" -eq 0 ]

  run grep -c "google/protobuf" "$PROTOC_MOCK_LOG"
  [ "$output" = "0" ]
}

@test "rust protoc: a non-well-known google import IS compiled as a transitive dependency" {
  mkdir -p "$IN/protos/google/api"
  printf 'syntax = "proto3";\npackage google.api;\nmessage HttpRule {}\n' \
    > "$IN/protos/google/api/annotations.proto"
  printf 'syntax = "proto3";\npackage library;\nimport "google/api/annotations.proto";\nmessage Test {}\n' \
    > "$IN/protos/library/test.proto"

  run_rust protos library
  [ "$status" -eq 0 ]

  run protoc_input_protos
  echo "$output"
  [[ "$output" == *"google/api/annotations.proto"* ]]
  [[ "$output" == *"library/test.proto"* ]]
}

# ------------------------------------------------------- transitive dependency closure

@test "rust deps: a transitive chain a -> b -> c -> d reaches protoc in full" {
  # prost only emits a module for a package protoc was ASKED to generate, so the whole
  # closure - not just the entry protos - has to end up on the command line. Only
  # library/ is compiled, so b/c/d can reach protoc as resolved dependencies alone.
  mkdir -p "$IN/protos/chain"
  printf 'syntax = "proto3";\npackage library;\nimport "chain/b.proto";\nmessage A { chain.B b = 1; }\n' \
    > "$IN/protos/library/test.proto"
  printf 'syntax = "proto3";\npackage chain;\nimport "chain/c.proto";\nmessage B { C c = 1; }\n' \
    > "$IN/protos/chain/b.proto"
  printf 'syntax = "proto3";\npackage chain;\nimport "chain/d.proto";\nmessage C { D d = 1; }\n' \
    > "$IN/protos/chain/c.proto"
  printf 'syntax = "proto3";\npackage chain;\nmessage D { string name = 1; }\n' \
    > "$IN/protos/chain/d.proto"

  run_rust protos library
  [ "$status" -eq 0 ]

  run protoc_input_protos
  echo "$output"
  [ "$output" = "chain/b.proto
chain/c.proto
chain/d.proto
library/test.proto" ]
}

@test "rust deps: an import written relative to the importing proto is resolved and compiled" {
  # "../dependency/relonly.proto" does NOT resolve against the proto root; it only
  # resolves next to the file that imports it. Compiling library/ alone means the
  # dependency can only appear on protoc's command line through that second
  # resolution attempt - it is never an entry proto itself.
  printf 'syntax = "proto3";\npackage library;\nimport "../dependency/relonly.proto";\nmessage Test { dependency.RelOnly r = 1; }\n' \
    > "$IN/protos/library/test.proto"
  printf 'syntax = "proto3";\npackage dependency;\nmessage RelOnly { string name = 1; }\n' \
    > "$IN/protos/dependency/relonly.proto"
  # the same path relative to the proto ROOT must not exist, or the first (root-relative)
  # resolution would resolve it and the case under test would never be reached
  [ ! -e "$IN/dependency/relonly.proto" ]

  run_rust protos library
  [ "$status" -eq 0 ]

  run protoc_input_protos
  echo "$output"
  # canonicalised back to a proto-root-relative path, not the literal "../" spelling
  [ "$output" = "dependency/relonly.proto
library/test.proto" ]
}

@test "rust deps: an import that escapes the protos root is rejected before protoc" {
  # a proto reachable through the root with "../" but living OUTSIDE it cannot be
  # expressed as a -I-relative path, so protoc would be handed a nonsensical
  # "<root>/<absolute path>" argument. The pre-flight has to catch that.
  mkdir -p "$IN/outside"
  printf 'syntax = "proto3";\npackage outside;\nmessage Escaped { string name = 1; }\n' \
    > "$IN/outside/escaped.proto"
  printf 'syntax = "proto3";\npackage library;\nimport "../outside/escaped.proto";\nmessage Test { outside.Escaped e = 1; }\n' \
    > "$IN/protos/library/test.proto"

  run_rust protos library
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist under the protos root"* ]]
  [[ "$output" == *"outside/escaped.proto"* ]]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]

  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$CARGO_MOCK_LOG" ]
  [ ! -d "$OUT/src" ]
}

@test "rust deps: a proto path carrying a newline is rejected instead of mis-compiled" {
  # find/read hand such a path to the resolver in fragments, so what comes back out
  # is not a real file. That must fail the run loudly rather than send protoc a
  # truncated path (or, worse, silently compile only half the tree).
  rm -f "$IN/protos/library/test.proto"
  printf 'syntax = "proto3";\npackage library;\nmessage Test {}\n' \
    > "$IN/protos/library/we
ird.proto"

  run_rust protos
  [ "$status" -ne 0 ]
  # The resolver now rejects the mangled fragment on sight; before that guard the run
  # got as far as the stub script's post-resolution existence check ("does not exist
  # under the protos root"), which cpp's pipeline has no equivalent of - there the same
  # input silently compiled the fragment and exited 0.
  # the rejected path is the LEADING fragment the newline split off ("…/protos/we"),
  # which is what identifies the offending proto to whoever has to fix the tree
  [[ "$output" == *"library/we' is not a readable .proto file"* ]]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]

  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$CARGO_MOCK_LOG" ]
  [ ! -d "$OUT/src" ]
}

# ------------------------------------------------------------------- no-protos guard

@test "rust guard: an empty protos root fails loudly and never runs protoc or cargo" {
  rm -f "$IN/protos/library/test.proto" "$IN/protos/dependency/myimport.proto"

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found"* ]]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$CARGO_MOCK_LOG" ]
  [ ! -d "$OUT/src" ]
}

@test "rust guard: a DIRECTORY named *.proto does not satisfy the no-protos guard" {
  rm -f "$IN/protos/library/test.proto" "$IN/protos/dependency/myimport.proto"
  mkdir -p "$IN/protos/library/decoy.proto"

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "rust guard: a proto without a 'package' declaration is rejected by name" {
  printf 'syntax = "proto3";\nmessage Test {}\n' > "$IN/protos/library/test.proto"
  rm -f "$IN/protos/dependency/myimport.proto"

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"'library/test.proto' declares no 'package'"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "rust guard: an unresolvable import aborts dependency resolution" {
  printf 'syntax = "proto3";\npackage library;\nimport "nowhere/missing.proto";\nmessage Test {}\n' \
    > "$IN/protos/library/test.proto"

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to resolve dependency"* ]]
  [[ "$output" == *"proto dependency resolution failed"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "rust guard: a manifest template path containing a comma is rejected" {
  # protoc joins every --prost-crate_opt param with commas, so a comma in the path
  # would silently split gen_crate= into two options.
  export TEMP_SRC_DIRECTORY="$SANDBOX/tmp,src"
  printf '[package]\nname = "x"\nversion = "1.0.0"\n' > "$IN/Cargo.toml"

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"contains a comma"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

# --------------------------------------------------- protoc / cargo post-conditions

@test "rust post-condition: protoc exiting 0 without writing src/api/mod.rs fails the run" {
  # protoc reports a plugin that never produced a CodeGeneratorResponse as success, so
  # a prost-crate plugin that silently did not run leaves a crate whose barrel does not
  # exist. Shipping that is worse than failing.
  shadow_protoc <<'MOCK'
#!/usr/bin/env bash
# prost + tonic wrote their per-package files; protoc-gen-prost-crate did not run
: "${PROTOC_MOCK_LOG:=/dev/null}"
printf 'protoc %s\n' "$*" >> "$PROTOC_MOCK_LOG"
for a in "$@"; do
  case "$a" in
    --prost_out=*|--tonic_out=*)
      dir="${a#*=}"
      mkdir -p "$dir"
      : > "$dir/mock.package.rs"
      ;;
  esac
done
exit 0
MOCK

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"protoc produced no 'src/api/mod.rs'"* ]]
  [[ "$output" == *"the prost-crate plugin did not run"* ]]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]

  # protoc really was invoked - this is the post-condition failing, not an earlier guard
  [ -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$CARGO_MOCK_LOG" ]
  [ ! -d "$OUT/src" ]
  [ ! -f "$OUT/Cargo.toml" ]
}

@test "rust post-condition: protoc writing no Cargo.toml from gen_crate= fails the run" {
  # the include file landed but the manifest did not: a crate directory that cargo
  # cannot even read a package name out of.
  shadow_protoc <<'MOCK'
#!/usr/bin/env bash
# the include file named by include_file= was written; gen_crate= produced nothing
: "${PROTOC_MOCK_LOG:=/dev/null}"
printf 'protoc %s\n' "$*" >> "$PROTOC_MOCK_LOG"
for a in "$@"; do
  case "$a" in
    --prost_out=*|--tonic_out=*)
      dir="${a#*=}"
      mkdir -p "$dir"
      : > "$dir/mock.package.rs"
      : > "$dir/mod.rs"
      ;;
  esac
done
exit 0
MOCK

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"protoc produced no 'Cargo.toml' from gen_crate="* ]]
  [[ "$output" == *"$IMG/default-lib-files/Cargo.toml"* ]]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]

  [ -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$CARGO_MOCK_LOG" ]
  [ ! -f "$OUT/Cargo.toml" ]
}

@test "rust post-condition: 'cargo package' leaving no package directory fails the run" {
  shadow_cargo <<'MOCK'
#!/usr/bin/env bash
# both subcommands succeed, but nothing is ever staged in $CARGO_TARGET_DIR/package
: "${CARGO_MOCK_LOG:=/dev/null}"
printf 'cargo %s\n' "$*" >> "$CARGO_MOCK_LOG"
exit 0
MOCK

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"'cargo package' created no package directory"* ]]
  [[ "$output" == *"$IMG/cargo-target"* ]]
  [[ "$output" == *"ERROR: compile-stubs-2-lib.sh failed"* ]]

  # both cargo steps ran: it is the post-condition that failed, not the build
  grep -Fq "cargo build --release --offline" "$CARGO_MOCK_LOG"
  grep -Fq "cargo package --offline --no-verify --allow-dirty" "$CARGO_MOCK_LOG"
  # ... and nothing was copied out
  [ ! -d "$OUT/src" ]
  [ ! -d "$OUT/crate-dist" ]
  [ ! -f "$OUT/Cargo.toml" ]
}

@test "rust post-condition: a package directory without a .crate artifact fails the run" {
  # cargo staged the crate tree but produced no tarball. A .crate file nested INSIDE
  # the staged tree must not rescue it either - the artifact lookup is -maxdepth 1,
  # because only the tarball beside the staging directory is the publishable one.
  shadow_cargo <<'MOCK'
#!/usr/bin/env bash
: "${CARGO_MOCK_LOG:=/dev/null}"
printf 'cargo %s\n' "$*" >> "$CARGO_MOCK_LOG"
for a in "$@"; do
  case "$a" in
    package)
      mkdir -p "$CARGO_TARGET_DIR/package/ondewo-proto-stubs-0.0.1/src"
      : > "$CARGO_TARGET_DIR/package/ondewo-proto-stubs-0.0.1/decoy.crate"
      ;;
  esac
done
exit 0
MOCK

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"'cargo package' produced no .crate artifact"* ]]
  [[ "$output" == *"$IMG/cargo-target/package"* ]]
  [[ "$output" == *"ERROR: compile-stubs-2-lib.sh failed"* ]]

  [ -d "$IMG/cargo-target/package/ondewo-proto-stubs-0.0.1" ]
  [ ! -d "$OUT/crate-dist" ]
  [ ! -d "$OUT/src" ]
}

# -------------------------------------------------------------- failure propagation

@test "rust failure: compile-proto-2-stubs.sh failure aborts the orchestrator" {
  rm -f "$IN/protos/library/test.proto" "$IN/protos/dependency/myimport.proto"

  run_rust protos
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]
}

@test "rust failure: make-lib-entry-point.sh failure aborts the orchestrator" {
  rm -f "$IMG/default-lib-files/lib.rs"

  run_rust protos
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: make-lib-entry-point.sh failed"* ]]
  [ ! -s "$CARGO_MOCK_LOG" ]
  [ ! -d "$OUT/src" ]
}

@test "rust failure: a failing 'cargo build' aborts and copies nothing out" {
  export CARGO_FAIL_MATCH="build"

  run_rust protos
  [ "$status" -eq 1 ]
  [[ "$output" == *"'cargo build' failed - the generated crate does not compile"* ]]
  [[ "$output" == *"ERROR: compile-stubs-2-lib.sh failed"* ]]
  [ ! -d "$OUT/src" ]
  [ ! -d "$OUT/crate-dist" ]
}

@test "rust failure: a failing 'cargo package' aborts the orchestrator" {
  export CARGO_FAIL_MATCH="package"

  run_rust protos
  [ "$status" -eq 1 ]
  [[ "$output" == *"'cargo package' failed"* ]]
  [[ "$output" == *"ERROR: compile-stubs-2-lib.sh failed"* ]]
  # the build step still ran; only packaging blew up
  grep -Fq "cargo build --release --offline" "$CARGO_MOCK_LOG"
  [ ! -d "$OUT/crate-dist" ]
}

@test "rust failure: a non-zero cargo exit code propagates as a non-zero orchestrator exit" {
  export CARGO_FAIL_MATCH="build"
  export CARGO_FAIL_RC=42

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: compile-stubs-2-lib.sh failed"* ]]
}

# ------------------------------------------------------- offline dependency pre-flight

@test "rust offline: a dependency missing from the pre-warmed cache aborts before cargo" {
  find "$CARGO_REGISTRY_HOME/registry/cache" -type f -name 'tonic-prost-*.crate' -exec rm -f {} +

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"dependency 'tonic-prost' is not in the image's pre-warmed cargo cache"* ]]
  [[ "$output" == *"SKIP_CARGO_BUILD=1"* ]]
  [[ "$output" == *"ERROR: compile-stubs-2-lib.sh failed"* ]]
  # the whole point: cargo is never reached
  [ ! -s "$CARGO_MOCK_LOG" ]
}

@test "rust offline: a cached crate that merely shares a name prefix does not satisfy a dep" {
  # prost-types-0.14.4.crate must NOT be mistaken for the crate "prost"
  rm -rf "$CARGO_REGISTRY_HOME/registry/cache"
  mkdir -p "$CARGO_REGISTRY_HOME/registry/cache/mock-registry"
  : > "$CARGO_REGISTRY_HOME/registry/cache/mock-registry/prost-types-0.14.4.crate"

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"dependency 'prost' is not in the image's pre-warmed cargo cache"* ]]
}

@test "rust offline: a [dependencies.<name>] sub-table is pre-flighted too" {
  # a feature-heavy client dependency written as its own TOML table must not sail past
  printf '[package]\nname = "client"\nversion = "1.0.0"\n\n[dependencies]\nprost = "0.14"\n\n[dependencies.tokio]\nversion = "1"\nfeatures = ["full"]\n' \
    > "$IN/Cargo.toml"
  find "$CARGO_REGISTRY_HOME/registry/cache" -type f -name 'tokio-*.crate' -exec rm -f {} +

  run_rust protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"dependency 'tokio' is not in the image's pre-warmed cargo cache"* ]]
  [ ! -s "$CARGO_MOCK_LOG" ]
}

@test "rust offline: no registry cache at all degrades to a warning, not a failure" {
  rm -rf "$CARGO_REGISTRY_HOME"

  run_rust protos
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping the offline dependency pre-flight"* ]]
  grep -Fq "cargo build --release --offline" "$CARGO_MOCK_LOG"
}

@test "rust offline: every dependency of the shipped manifest is pre-warmed into the image" {
  # The image bakes CARGO_NET_OFFLINE=true, so a default-manifest dependency that the
  # pre-warm manifest does not list can never be fetched - every run would fail.
  prewarmed=" $(manifest_dependencies "$REPO_ROOT/$PREWARM_MANIFEST" | tr '\n' ' ')"
  missing=""
  for dep in $(manifest_dependencies "$REPO_ROOT/$DEFAULT_MANIFEST"); do
    case "$prewarmed" in
      *" $dep "*) ;;
      *) missing="$missing $dep" ;;
    esac
  done
  echo "not pre-warmed:$missing"
  [ -n "$prewarmed" ]
  [ -z "$missing" ]
}

@test "rust offline: both cargo invocations are put into offline mode" {
  run_rust protos
  [ "$status" -eq 0 ]
  run bash -c "grep -c -- '--offline' '$CARGO_MOCK_LOG'"
  [ "$output" = "2" ]
}

# ------------------------------------------------------------------ escape hatch / env

@test "rust SKIP_CARGO_BUILD=1: stubs are emitted, cargo is never invoked" {
  export SKIP_CARGO_BUILD=1

  run_rust protos
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping the cargo build/package step"* ]]
  [[ "$output" == *"no packaged"* ]]

  [ ! -s "$CARGO_MOCK_LOG" ]
  [ -f "$OUT/Cargo.toml" ]
  [ -f "$OUT/src/api/mod.rs" ]
  [ ! -d "$OUT/crate-dist" ]
}

@test "rust SKIP_CARGO_BUILD=1: escapes a pre-flight failure it is meant to escape" {
  # the hatch must be evaluated BEFORE the offline pre-flight, or it escapes nothing
  export SKIP_CARGO_BUILD=1
  rm -rf "$CARGO_REGISTRY_HOME/registry/cache"
  mkdir -p "$CARGO_REGISTRY_HOME/registry/cache/mock-registry"

  run_rust protos
  [ "$status" -eq 0 ]
  [[ "$output" != *"is not in the image's pre-warmed cargo cache"* ]]
  [ -f "$OUT/src/api/mod.rs" ]
}

@test "rust env: an ambient CARGO_TARGET_DIR cannot redirect the build or the artifact" {
  export CARGO_TARGET_DIR="$SANDBOX/hijacked"

  run_rust protos
  [ "$status" -eq 0 ]

  [ ! -e "$SANDBOX/hijacked" ]
  [ -d "$IMG/cargo-target/package" ]
  run bash -c "find '$OUT/crate-dist' -name '*.crate' | grep -c ."
  [ "$output" = "1" ]
}

# ------------------------------------------------------------------- crate barrel

@test "rust barrel: the default lib.rs is copied and declares every hand-written module" {
  mkdir -p "$IN/src/auth"
  printf 'pub fn token() {}\n' > "$IN/src/auth/mod.rs"
  printf 'pub fn helper() {}\n' > "$IN/src/support.rs"

  run_rust protos
  [ "$status" -eq 0 ]
  [[ "$output" == *"No src/lib.rs specified in source directory"* ]]

  grep -Fq "pub mod api;" "$OUT/src/lib.rs"        # default barrel header
  grep -Fq "pub mod auth;" "$OUT/src/lib.rs"
  grep -Fq "pub mod support;" "$OUT/src/lib.rs"
  # the generated tree is never declared twice
  run bash -c "grep -c '^pub mod api;' '$OUT/src/lib.rs'"
  [ "$output" = "1" ]
}

@test "rust barrel: names that are not rust identifiers are warned about, not declared" {
  mkdir -p "$IN/src/my-helpers" "$IN/src/blobs"
  printf 'pub fn h() {}\n' > "$IN/src/my-helpers/mod.rs"
  printf 'not rust\n'      > "$IN/src/blobs/data.txt"
  printf 'notes\n'         > "$IN/src/README.txt"

  run_rust protos
  [ "$status" -eq 0 ]
  [[ "$output" == *"'src/my-helpers' is not a valid rust module name"* ]]
  [[ "$output" == *"'src/blobs/' carries no mod.rs"* ]]

  # POSIX ERE alternation: BSD/macOS grep has no BRE `\|`
  run bash -c "grep -cE 'my-helpers|blobs|README' '$OUT/src/lib.rs'"
  [ "$output" = "0" ]
}

@test "rust barrel: a hand-written src/lib.rs in the input volume is left untouched" {
  mkdir -p "$IN/src"
  printf '// my own barrel\npub mod api;\npub mod auth;\n' > "$IN/src/lib.rs"
  mkdir -p "$IN/src/auth"
  printf 'pub fn token() {}\n' > "$IN/src/auth/mod.rs"

  run_rust protos
  [ "$status" -eq 0 ]
  [[ "$output" == *"leaving it untouched"* ]]

  run diff "$IN/src/lib.rs" "$OUT/src/lib.rs"
  [ "$status" -eq 0 ]
}

# ------------------------------------------------- sub-scripts driven directly (units)

@test "rust unit: compile-proto-2-stubs.sh rejects missing arguments" {
  run bash "$IMG/compile-proto-2-stubs.sh" "$CRATE" "$IN/protos"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-proto-2-stubs.sh"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "rust unit: compile-proto-2-stubs.sh rejects a missing protos root directory" {
  run bash "$IMG/compile-proto-2-stubs.sh" \
    "$CRATE" "$SANDBOX/no-such-root" "$SANDBOX/no-such-root/library" "$REPO_ROOT/$DEFAULT_MANIFEST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the protos root directory '$SANDBOX/no-such-root' does not exist"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  # the crate output directories are created only after the source checks pass
  [ ! -d "$CRATE" ]
}

@test "rust unit: compile-proto-2-stubs.sh rejects a missing protos source directory" {
  # the root exists, the compiled sub-directory does not
  run bash "$IMG/compile-proto-2-stubs.sh" \
    "$CRATE" "$IN/protos" "$IN/protos/no-such-subdir" "$REPO_ROOT/$DEFAULT_MANIFEST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the protos source directory '$IN/protos/no-such-subdir' does not exist"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -d "$CRATE" ]
}

@test "rust unit: compile-proto-2-stubs.sh rejects a missing crate manifest template" {
  # both proto directories are fine; there is just nothing to hand protoc as gen_crate=
  run bash "$IMG/compile-proto-2-stubs.sh" \
    "$CRATE" "$IN/protos" "$IN/protos/library" "$SANDBOX/no-such-Cargo.toml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"The crate manifest template '$SANDBOX/no-such-Cargo.toml' does not exist"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -d "$CRATE" ]
}

@test "rust unit: compile-stubs-2-lib.sh rejects missing arguments" {
  run bash "$IMG/compile-stubs-2-lib.sh" "$CRATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-stubs-2-lib.sh"* ]]
  [ ! -s "$CARGO_MOCK_LOG" ]
}

@test "rust unit: compile-stubs-2-lib.sh refuses a crate without a Cargo.toml" {
  mkdir -p "$CRATE/src"
  printf '// barrel\n' > "$CRATE/src/lib.rs"

  run bash "$IMG/compile-stubs-2-lib.sh" "$CRATE" "$SANDBOX/dist"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the protoc gen_crate step did not run"* ]]
  [ ! -s "$CARGO_MOCK_LOG" ]
}

@test "rust unit: compile-stubs-2-lib.sh refuses a crate without src/lib.rs" {
  mkdir -p "$CRATE/src"
  cp "$REPO_ROOT/$DEFAULT_MANIFEST" "$CRATE/Cargo.toml"

  run bash "$IMG/compile-stubs-2-lib.sh" "$CRATE" "$SANDBOX/dist"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the crate has no entry point"* ]]
  [ ! -s "$CARGO_MOCK_LOG" ]
}

@test "rust unit: make-lib-entry-point.sh refuses a crate without a src directory" {
  run bash "$IMG/make-lib-entry-point.sh" "$SANDBOX/no-such-crate"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "rust unit: make-lib-entry-point.sh with no argument prints usage and writes nothing" {
  # an empty $1 would otherwise make the barrel path "/src/lib.rs" - at the filesystem
  # root, outside the crate entirely
  run bash "$IMG/make-lib-entry-point.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: make-lib-entry-point.sh <crate_dir>"* ]]
  [ ! -e "$CRATE" ]
  [ ! -e "$IMG/src/lib.rs" ]
}
