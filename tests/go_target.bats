#!/usr/bin/env bats
# End-to-end and unit tests for the `go` proto-compiler target, driven on the
# HOST: the container paths (/image-data, /input-volume, /output-volume) are
# overridden through the env knobs the scripts expose and the toolchain (protoc
# with its two go plugins, `go`) is PATH-mocked, so the whole pipeline — input
# copy, stub generation, module manifest rendering, `go build`, copy-back — is
# exercised without Docker, a network or a real go toolchain.
#
# What the go target does differently from the node targets, and what therefore
# gets pinned here:
#   * the go import path of a generated package is baked INTO the generated code,
#     so a `M<proto>=<import path>;<pkg name>` pair per non-google proto is built
#     from the module path (3rd argument, else the input volume's go.mod) — the
#     mappings cover every proto under the ROOT, the compiled set only the
#     selected sub-directory;
#   * google/** is never generated (its go packages come from
#     google.golang.org/protobuf and .../genproto) — neither compiled nor mapped;
#   * there is no barrel/entry-point file: what makes the generated directories
#     importable is go.mod, rendered from default-lib-files/go.mod.template, and
#     it is only written to the output volume when the client has none.
#
# The image-data tree is copied into the sandbox for every test (the scripts
# invoke their siblings as ./x.sh and stage into $IMAGE_DATA_DIRECTORY), so the
# repo tree is never written to.

load 'helpers/setup'

setup() {
  common_setup
  # Mock knobs have to be exported AFTER common_setup: it scrubs the whole GO_*
  # namespace (GOPATH/GOFLAGS/GOPROXY leaking in from the host would otherwise
  # reach the script under test) and only spares the *_MOCK_*/*_FAIL_* names.
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  export GO_MOCK_LOG="$SANDBOX/go.log"
  # ... and the extra-include knob is not in any namespace common_setup scrubs, so
  # an ambient value would add a -I root (or abort the run) on one machine only
  unset EXTRA_PROTO_DIRS

  IN="$SANDBOX/input"
  OUT="$SANDBOX/output"
  MODULE="github.com/ondewo/ondewo-nlu-client-go"

  mkdir -p "$IN/protos/dependency" "$OUT"
  printf 'syntax = "proto3";\npackage dependency;\nmessage MyImport { string name = 1; }\n' \
    > "$IN/protos/dependency/myimport.proto"
  printf 'syntax = "proto3";\npackage test;\nimport "dependency/myimport.proto";\nmessage Test { dependency.MyImport my_import = 1; }\nservice SimpleService { rpc SendTest (Test) returns (Test); }\n' \
    > "$IN/protos/test.proto"
}

teardown() { common_teardown; }

# Copy go/image-data into the sandbox, cd there (the orchestrator calls its
# siblings as ./compile-proto-2-*.sh) and point the container-path knobs at the
# sandbox. TEMP_SRC is the script's OWN default ($IMAGE_DATA_DIRECTORY/src) and
# is left unset in the environment on purpose, so the default is under test too.
stage() {
  cp -r "$REPO_ROOT/go/image-data" "$SANDBOX/image-data"
  # default-lib-files/go.sum is produced by the docker build and gitignored, so
  # it may or may not exist in a developer's tree -> drop it for a deterministic
  # starting state. The tests that care create it explicitly.
  rm -f "$SANDBOX/image-data/default-lib-files/go.sum"
  cd "$SANDBOX/image-data"
  export IMAGE_DATA_DIRECTORY="$SANDBOX/image-data"
  export INPUT_VOLUME_FS="$IN"
  export OUTPUT_VOLUME_FS="$OUT"
  TEMP_SRC="$SANDBOX/image-data/src"
}

run_compile() { run bash ./compile-proto-2-go.sh "$@"; }

# Content + layout fingerprint of a directory tree, used to prove the mounted
# input volume is only ever read. Sorted, so it does not depend on find's
# traversal order; cksum is in POSIX and behaves the same on GNU and BSD.
snapshot() { (cd "$1" && find . -print | sort && find . -type f -exec cksum {} + | sort); }

# Number of regular files below a directory (grep -c, never wc: BSD pads).
file_count() { find "$1" -type f | grep -c . || true; }

# ---------------------------------------------------------------- pipeline e2e

@test "go e2e: the full pipeline generates stubs, builds the module and copies api/ + go.mod out" {
  stage
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DONE: execute script compile-proto-2-go.sh"* ]]
  [ -f "$OUT/api/mock.pb.go" ]
  [ -f "$OUT/api/mock_grpc.pb.go" ]
  [ -f "$OUT/go.mod" ]
  # the manifest is the template with the module path substituted in
  run grep -Fqx "module $MODULE" "$OUT/go.mod"
  [ "$status" -eq 0 ]
  run grep -Fq '@GO_MODULE_PATH@' "$OUT/go.mod"
  [ "$status" -ne 0 ]
  # the package build really ran (and the go mock only succeeds with a go.mod in CWD)
  run grep -Fqx 'go build ./...' "$GO_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "go e2e: the mounted input volume is never mutated" {
  stage
  before="$(snapshot "$IN")"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  after="$(snapshot "$IN")"
  [ "$before" = "$after" ]
  # compilation happened out of the copy, not out of the mount
  [ -f "$TEMP_SRC/protos/test.proto" ]
  [ -d "$TEMP_SRC/api" ]
}

@test "go e2e: the output volume holds only the api/ tree and the module manifest (no barrel)" {
  stage
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  # 2 generated stubs + go.mod. Go has no entry-point/barrel concept, so nothing
  # like public-api.* may appear, and no go.sum is invented when the image has none.
  [ "$(file_count "$OUT")" -eq 3 ]
  [ ! -f "$OUT/go.sum" ]
  run bash -c "find '$OUT' -name 'public-api.*' -o -name '*.ts' | grep -c . || true"
  [ "$output" = "0" ]
}

@test "go e2e: the staged library is self-contained - hand-written sources are not built into it" {
  stage
  printf 'package auth\n\nfunc Token() string { return "" }\n' > "$IN/auth.go"
  mkdir -p "$IN/auth"
  printf 'package auth\n' > "$IN/auth/auth.go"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  # the built module is exactly the manifest + the generated stubs ...
  [ -f "$TEMP_SRC/lib/go.mod" ]
  [ -d "$TEMP_SRC/lib/api" ]
  [ ! -e "$TEMP_SRC/lib/auth.go" ]
  [ ! -e "$TEMP_SRC/lib/auth" ]
  # ... and hand-written sources are not copied into the output volume either
  [ ! -e "$OUT/auth.go" ]
  [ ! -e "$OUT/auth" ]
}

@test "go e2e: a second run over the same volumes is stable" {
  stage
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  first="$(snapshot "$OUT")"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [ "$(snapshot "$OUT")" = "$first" ]
}

@test "go e2e: a missing output volume falls back to <input volume>/lib" {
  stage
  export OUTPUT_VOLUME_FS="$SANDBOX/does-not-exist"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"creating output in sourcevolume/lib directory"* ]]
  [ -f "$IN/lib/api/mock.pb.go" ]
  [ -f "$IN/lib/api/mock_grpc.pb.go" ]
  [ -f "$IN/lib/go.mod" ]
  [ ! -d "$SANDBOX/does-not-exist" ]
}

# ------------------------------------------------------------- stale artefacts

@test "go e2e: a stub of a since-deleted proto does not survive in the output volume" {
  stage
  mkdir -p "$OUT/api/deleted"
  : > "$OUT/api/deleted/gone.pb.go"
  : > "$OUT/api/gone_grpc.pb.go"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [ ! -e "$OUT/api/deleted" ]
  [ ! -e "$OUT/api/gone_grpc.pb.go" ]
  [ -f "$OUT/api/mock.pb.go" ]
}

@test "go e2e: stale stubs inside the input volume are not restaged into the output" {
  # a go client repo IS the input volume, so it carries the api/ dir of the previous run
  stage
  mkdir -p "$IN/api"
  printf 'package api\n' > "$IN/api/stale.pb.go"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [ ! -e "$OUT/api/stale.pb.go" ]
  [ ! -e "$TEMP_SRC/api/stale.pb.go" ]
  # ... and the client's copy is still there: the mount was only read
  [ -f "$IN/api/stale.pb.go" ]
}

# ---------------------------------------------------------- argument handling

@test "go args: no arguments uses protos/ and the module path of the input volume's go.mod" {
  stage
  printf 'module github.com/from/gomod\n\ngo 1.25.0\n' > "$IN/go.mod"
  run_compile
  [ "$status" -eq 0 ]
  [[ "$output" == *"Go module path: github.com/from/gomod"* ]]
  run grep -Fq -- "--go_opt=Mtest.proto=github.com/from/gomod/api;api" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "-I $TEMP_SRC/protos " "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "go args: an explicit relative protos dir becomes protoc's -I root" {
  stage
  mkdir -p "$IN/my-protos"
  mv "$IN/protos/test.proto" "$IN/my-protos/test.proto"
  rm -rf "$IN/protos"
  run_compile my-protos "" "$MODULE"
  [ "$status" -eq 0 ]
  run grep -Fq -- "-I $TEMP_SRC/my-protos " "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- " $TEMP_SRC/my-protos/test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "go args: a trailing slash on the protos dir is normalised and google/** stays excluded" {
  # 'protos//' survives ${VAR%/} as 'protos/' and find keeps the start path
  # verbatim, so without the leading-separator strip the relative names would
  # start with '/' and the google exclusion would stop matching
  stage
  mkdir -p "$IN/protos/google/api"
  printf 'syntax = "proto3";\npackage google.api;\n' > "$IN/protos/google/api/annotations.proto"
  run_compile 'protos//' "" "$MODULE"
  [ "$status" -eq 0 ]
  run grep -Fq "annotations.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  run grep -Fq -- " $TEMP_SRC/protos/test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  [ -f "$OUT/api/mock.pb.go" ]
}

@test "go args: the target sub-directory scopes compilation but still maps every proto" {
  stage
  mkdir -p "$IN/protos/a" "$IN/protos/b"
  printf 'syntax = "proto3";\npackage a;\nmessage A {}\n' > "$IN/protos/a/a.proto"
  printf 'syntax = "proto3";\npackage b;\nmessage B {}\n' > "$IN/protos/b/b.proto"
  run_compile protos a "$MODULE"
  [ "$status" -eq 0 ]
  # compiled: only the selected sub-tree
  run grep -Fq -- " $TEMP_SRC/protos/a/a.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- " $TEMP_SRC/protos/b/b.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  run grep -Fq -- " $TEMP_SRC/protos/test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # mapped: every non-google proto under the ROOT, because protoc-gen-go needs an
  # import path for dependency files as well
  run grep -Fq -- "--go_opt=Mb/b.proto=$MODULE/api/b;b" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "--go-grpc_opt=Mtest.proto=$MODULE/api;api" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "go args: a trailing slash on the target sub-directory is normalised" {
  stage
  mkdir -p "$IN/protos/a"
  printf 'syntax = "proto3";\npackage a;\nmessage A {}\n' > "$IN/protos/a/a.proto"
  run_compile protos a/ "$MODULE"
  [ "$status" -eq 0 ]
  run grep -Fq -- " $TEMP_SRC/protos/a/a.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- " $TEMP_SRC/protos/test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # the doubled separator a naive "$ROOT/$2" would produce never appears
  run grep -Fq "protos/a//" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "go args: a trailing slash on the module path is normalised" {
  stage
  run_compile protos "" "$MODULE/"
  [ "$status" -eq 0 ]
  run grep -Fq -- "--go_opt=Mtest.proto=$MODULE/api;api" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fqx "module $MODULE" "$OUT/go.mod"
  [ "$status" -eq 0 ]
}

@test "go args: an unusable module path is rejected before protoc runs" {
  stage
  run_compile protos "" /absolute/path
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: '/absolute/path' is not a usable go module path"* ]]
  [[ "$output" == *"without whitespace and without a leading '/'"* ]]
  # the guard sits before the first compilation step: neither tool ran and the
  # output volume was never touched
  [ ! -f "$PROTOC_MOCK_LOG" ]
  [ ! -f "$GO_MOCK_LOG" ]
  [ "$(file_count "$OUT")" -eq 0 ]
}

@test "go args: a module path containing whitespace is rejected" {
  stage
  run_compile protos "" "github.com/x y"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: 'github.com/x y' is not a usable go module path"* ]]
  [[ "$output" == *"without whitespace and without a leading '/'"* ]]
  [ ! -f "$PROTOC_MOCK_LOG" ]
  [ ! -f "$GO_MOCK_LOG" ]
  [ "$(file_count "$OUT")" -eq 0 ]
}

@test "go args: the module path guard also rejects what the input volume's go.mod declares" {
  stage
  # The 3rd argument is not the only source of the module path - with none given
  # the `module` line of the mounted go.mod is used, and it reaches protoc's M
  # mappings and the rendered manifest just the same, so it faces the same guard.
  printf 'module /oops\n\ngo 1.25.0\n' > "$IN/go.mod"
  run_compile protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: '/oops' is not a usable go module path"* ]]
  # ... and it is the guard that stops it, not the "no go module path" branch
  [[ "$output" != *"ERROR: no go module path"* ]]
  [ ! -f "$PROTOC_MOCK_LOG" ]
  [ ! -f "$GO_MOCK_LOG" ]
  [ "$(file_count "$OUT")" -eq 0 ]
}

@test "go args: the module path guard writes to stderr and leaves the input volume untouched" {
  stage
  before="$(snapshot "$IN")"
  run bash -c "bash ./compile-proto-2-go.sh protos '' '/absolute/path' 2>'$SANDBOX/err.txt' >'$SANDBOX/out.txt'"
  [ "$status" -ne 0 ]
  run grep -Fq "is not a usable go module path" "$SANDBOX/err.txt"
  [ "$status" -eq 0 ]
  run grep -Fq "ERROR:" "$SANDBOX/out.txt"
  [ "$status" -ne 0 ]
  [ "$before" = "$(snapshot "$IN")" ]
}

@test "go args: no module path and no go.mod in the input volume fails loudly" {
  stage
  run_compile protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: no go module path"* ]]
  [[ "$output" == *"3rd argument"* ]]
  [ ! -f "$PROTOC_MOCK_LOG" ]
}

@test "go args: a nonexistent protos dir (1st argument) fails loudly" {
  stage
  run_compile nosuchdir "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the protos root directory 'nosuchdir'"* ]]
  [ ! -f "$GO_MOCK_LOG" ]
}

@test "go args: a nonexistent target sub-directory (2nd argument) fails loudly" {
  stage
  run_compile protos nosuchsub "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found"* ]]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]
  [ ! -f "$GO_MOCK_LOG" ]
}

# ----------------------------------------------------------- protoc invocation

@test "go protoc: both plugins write to the staged api dir with paths=source_relative" {
  stage
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  for flag in "-I $TEMP_SRC/protos" \
              "--go_out=$TEMP_SRC/api" \
              "--go_opt=paths=source_relative" \
              "--go-grpc_out=$TEMP_SRC/api" \
              "--go-grpc_opt=paths=source_relative"; do
    run grep -Fq -- "$flag" "$PROTOC_MOCK_LOG"
    [ "$status" -eq 0 ]
  done
  # exactly one protoc call - the go target has no second "dependency" pass
  [ "$(grep -c '^protoc ' "$PROTOC_MOCK_LOG")" -eq 1 ]
}

@test "go protoc: google/** well-known types are neither compiled nor import-mapped" {
  stage
  mkdir -p "$IN/protos/google/protobuf"
  printf 'syntax = "proto3";\npackage google.protobuf;\nmessage Empty {}\n' \
    > "$IN/protos/google/protobuf/empty.proto"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  run grep -Fq "empty.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  run grep -Fq "Mgoogle/" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # the non-google protos of the same tree are still compiled
  run grep -Fq -- " $TEMP_SRC/protos/test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "go protoc: every non-google proto is mapped to <module>/api/<dir> with a sanitised package name" {
  stage
  mkdir -p "$IN/protos/my-dir"
  printf 'syntax = "proto3";\npackage md;\nmessage M {}\n' > "$IN/protos/my-dir/x.proto"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  # a proto at the root maps onto the api package itself ...
  run grep -Fq -- "--go_opt=Mtest.proto=$MODULE/api;api" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # ... a sub-directory onto <module>/api/<dir>, with '-' sanitised in the go
  # package NAME only (the import path keeps it), and no trailing '_' (the `tr`
  # variant of that sed would rewrite the newline too)
  run grep -Fq -- "--go_opt=Mmy-dir/x.proto=$MODULE/api/my-dir;my_dir " "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- ";my_dir_" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # every mapping is passed to BOTH plugins
  run grep -Fq -- "--go-grpc_opt=Mmy-dir/x.proto=$MODULE/api/my-dir;my_dir" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "--go_opt=Mdependency/myimport.proto=$MODULE/api/dependency;dependency" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

# --------------------------------------------------- extra protoc include roots
# Most ONDEWO APIs vendor the google protos at <protos root>/google/..., which the
# single -I on the protos root already resolves. The survey API keeps them at
# <protos root>/googleapis/google/... instead, where `import
# "google/api/annotations.proto"` resolves against nothing ("File not found").
# EXTRA_PROTO_DIRS adds such a tree as a second -I root; its default auto-detects
# exactly the googleapis layout, so the roots that already worked are untouched.

# Stage the survey-style layout: the google protos one level deeper, under
# googleapis/, and no google/ at the protos root.
stage_googleapis_layout() {
  mkdir -p "$IN/protos/googleapis/google/api"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Http {}\n' \
    > "$IN/protos/googleapis/google/api/annotations.proto"
}

@test "go extra includes: googleapis/ is auto-detected as a second -I root" {
  stage
  stage_googleapis_layout
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Extra protoc include roots: -I $TEMP_SRC/protos/googleapis"* ]]
  run grep -Fq -- "-I $TEMP_SRC/protos/googleapis" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # the protos root stays the FIRST -I - the extra one is additive, never a replacement
  run grep -Fq -- "-I $TEMP_SRC/protos -I $TEMP_SRC/protos/googleapis" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "go extra includes: a root that has no googleapis/ gets no extra -I" {
  stage
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Extra protoc include roots"* ]]
  run grep -Fq -- " -I $TEMP_SRC/protos " "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Eq -- '-I [^ ]+ -I ' "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "go extra includes: a root with its own google/ keeps the single -I even beside a googleapis/" {
  stage
  stage_googleapis_layout
  # the nlu/csi/vtsi layout: google/** at the protos root already resolves, so the
  # auto-detection must stay out of the way rather than add a competing root
  mkdir -p "$IN/protos/google/protobuf"
  printf 'syntax = "proto3";\npackage google.protobuf;\nmessage Empty {}\n' \
    > "$IN/protos/google/protobuf/empty.proto"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Extra protoc include roots"* ]]
  run grep -Fq -- "-I $TEMP_SRC/protos/googleapis" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "go extra includes: protos below the extra root are neither compiled nor import-mapped" {
  stage
  stage_googleapis_layout
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  # protoc resolves them under their OWN root, so a mapping keyed on the path seen
  # here would never match, and their go packages come from .../genproto anyway
  run grep -Fq "Mgoogleapis/" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  run grep -Fq "annotations.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # the module's own protos are still compiled and mapped
  run grep -Fq -- " $TEMP_SRC/protos/test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "--go_opt=Mtest.proto=$MODULE/api;api" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "go extra includes: the exclusion is anchored on a directory boundary" {
  stage
  stage_googleapis_layout
  # "googleapis-fork" merely STARTS with the excluded name - it is a directory of
  # the module and has to keep its stubs and its import mapping
  mkdir -p "$IN/protos/googleapis-fork"
  printf 'syntax = "proto3";\npackage fork;\nmessage F {}\n' > "$IN/protos/googleapis-fork/f.proto"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  run grep -Fq -- "--go_opt=Mgoogleapis-fork/f.proto=$MODULE/api/googleapis-fork;googleapis_fork" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- " $TEMP_SRC/protos/googleapis-fork/f.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "go extra includes: EXTRA_PROTO_DIRS overrides the auto-detection" {
  stage
  stage_googleapis_layout
  mkdir -p "$IN/protos/vendor/google/api"
  printf 'syntax = "proto3";\npackage google.api;\nmessage V {}\n' \
    > "$IN/protos/vendor/google/api/v.proto"
  export EXTRA_PROTO_DIRS=vendor
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  run grep -Fq -- "-I $TEMP_SRC/protos/vendor" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # an explicit value REPLACES the auto-detected one, it does not extend it
  run grep -Fq -- "-I $TEMP_SRC/protos/googleapis" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # ... so googleapis/ is now an ordinary directory of the module again
  run grep -Fq -- "--go_opt=Mgoogleapis/google/api/annotations.proto=" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "go extra includes: EXTRA_PROTO_DIRS takes several directories and normalises trailing slashes" {
  stage
  mkdir -p "$IN/protos/first/google/api" "$IN/protos/second/google/type"
  printf 'syntax = "proto3";\npackage google.api;\nmessage A {}\n' \
    > "$IN/protos/first/google/api/a.proto"
  printf 'syntax = "proto3";\npackage google.type;\nmessage B {}\n' \
    > "$IN/protos/second/google/type/b.proto"
  export EXTRA_PROTO_DIRS="first/ second"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  # a doubled separator would leave a prefix no rel_proto starts with, so both the
  # -I path and the exclusion have to survive the trailing slash
  run grep -Fq -- "-I $TEMP_SRC/protos/first -I $TEMP_SRC/protos/second" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "//" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  run grep -Eq -- "Mfirst/|Msecond/" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "go extra includes: a nonexistent EXTRA_PROTO_DIRS entry fails loudly before protoc runs" {
  stage
  export EXTRA_PROTO_DIRS=not-here
  run_compile protos "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the extra include directory 'not-here' (EXTRA_PROTO_DIRS) does not exist"* ]]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]
  [ ! -f "$PROTOC_MOCK_LOG" ]
  [ ! -f "$GO_MOCK_LOG" ]
}

@test "go extra includes: the EXTRA_PROTO_DIRS guard writes to stderr and leaves the volumes alone" {
  stage
  before="$(snapshot "$IN")"
  export EXTRA_PROTO_DIRS=not-here
  run bash -c "bash ./compile-proto-2-go.sh protos '' '$MODULE' 2>/dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" != *"EXTRA_PROTO_DIRS"* ]]
  [ "$before" = "$(snapshot "$IN")" ]
  [ "$(file_count "$OUT")" -eq 0 ]
}

# ------------------------------------------------------------- no-protos guard

@test "go guard: an empty protos dir fails loudly and never runs the package build" {
  stage
  rm -f "$IN/protos/test.proto" "$IN/protos/dependency/myimport.proto"
  run_compile protos "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found"* ]]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]
  [ ! -f "$GO_MOCK_LOG" ]
  [ ! -e "$OUT/api" ]
}

@test "go guard: a protos dir holding only google/** fails loudly and never runs the package build" {
  stage
  rm -f "$IN/protos/test.proto" "$IN/protos/dependency/myimport.proto"
  mkdir -p "$IN/protos/google/protobuf"
  printf 'syntax = "proto3";\npackage google.protobuf;\nmessage Any {}\n' \
    > "$IN/protos/google/protobuf/any.proto"
  run_compile protos "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"only google/** protos were found"* ]]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]
  [ ! -f "$GO_MOCK_LOG" ]
}

@test "go guard: a DIRECTORY named *.proto does not satisfy the no-protos guard" {
  stage
  rm -f "$IN/protos/test.proto" "$IN/protos/dependency/myimport.proto"
  mkdir -p "$IN/protos/not-a-file.proto"
  run_compile protos "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found"* ]]
  run grep -Fq "not-a-file.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "go guard: a DIRECTORY named *.go in the stubs tree is not counted as generated output" {
  # the count is informational, but it is the one place that reports how much
  # protoc produced - a directory must never inflate it
  mkdir -p "$SANDBOX/countbin"
  cat > "$SANDBOX/countbin/protoc" <<'MOCK'
#!/usr/bin/env bash
# protoc shim: two stub files plus a DIRECTORY whose name ends in .go
for a in "$@"; do
  case "$a" in
    --go_out=*)      d="${a#--go_out=}";      mkdir -p "$d/nested.go"; : > "$d/mock.pb.go" ;;
    --go-grpc_out=*) d="${a#--go-grpc_out=}"; mkdir -p "$d";           : > "$d/mock_grpc.pb.go" ;;
  esac
done
MOCK
  chmod +x "$SANDBOX/countbin/protoc"
  PATH="$SANDBOX/countbin:$PATH"
  run bash "$REPO_ROOT/go/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/api" "$IN/protos" "$IN/protos" "$MODULE/api"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/api/nested.go" ]
  [[ "$output" == *"files generated by proto compilation: 2"* ]]
}

# ------------------------------------------------------------------- symlinks
# The input volume is staged with `cp -r`, which copies symlinks verbatim, so a
# .proto a client symlinked into its protos dir arrives as a link in the
# compilation copy. Excluding it would drop a service from the client silently,
# which is why the two proto finds filter with `[ -f ]` (follows links) instead
# of find's own -type f (does not).

@test "go symlinks: a .proto symlinked into the protos dir is compiled and import-mapped" {
  stage
  mkdir -p "$IN/vendor"
  printf 'syntax = "proto3";\npackage extra;\nmessage Extra {}\n' > "$IN/vendor/extra.proto"
  ln -s ../vendor/extra.proto "$IN/protos/extra.proto"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  run grep -Fq -- " $TEMP_SRC/protos/extra.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "--go_opt=Mextra.proto=$MODULE/api;api" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # the link is still a link in the copy - nothing was materialised in the mount
  [ -L "$IN/protos/extra.proto" ]
}

@test "go symlinks: a protos dir holding only a symlinked .proto passes the no-protos guard" {
  stage
  rm -f "$IN/protos/test.proto" "$IN/protos/dependency/myimport.proto"
  mkdir -p "$IN/vendor"
  printf 'syntax = "proto3";\npackage only;\nmessage Only {}\n' > "$IN/vendor/only.proto"
  ln -s ../vendor/only.proto "$IN/protos/only.proto"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 1 .proto files"* ]]
  [ -f "$OUT/api/mock.pb.go" ]
}

@test "go symlinks: a .proto symlink that dangles in the copy fails loudly instead of vanishing" {
  # a link out of the mounted volume survives `cp -r` as a link and resolves to
  # nothing in the compilation copy -> it must not be skipped in silence
  stage
  ln -s /nowhere/gone.proto "$IN/protos/gone.proto"
  run_compile protos "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"do not resolve to a file"* ]]
  [[ "$output" == *"gone.proto"* ]]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]
  [ ! -f "$PROTOC_MOCK_LOG" ]
  [ ! -e "$OUT/api" ]
}

@test "go symlinks: a DIRECTORY named *.proto under the root earns no import mapping" {
  stage
  mkdir -p "$IN/protos/decoy.proto"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  run grep -Fq -- "Mdecoy.proto=" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  run grep -Fq -- " $TEMP_SRC/protos/decoy.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # the real protos beside it are still compiled
  run grep -Fq -- " $TEMP_SRC/protos/test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "go guard: a missing input volume fails loudly with the mount hint" {
  stage
  export INPUT_VOLUME_FS="$SANDBOX/never-mounted"
  run_compile protos "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist - mount the directory holding the protos"* ]]
  [[ "$output" == *"/input-volume"* ]]
}

@test "go guard: an empty input volume fails loudly instead of compiling nothing" {
  stage
  rm -rf "$IN"
  mkdir -p "$IN"
  run_compile protos "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: failed to copy input volume contents"* ]]
  [ ! -f "$GO_MOCK_LOG" ]
}

# -------------------------------------------------------- failure propagation

@test "go failure: a failing protoc aborts the orchestrator" {
  # the shared protoc mock has no failure knob (it only mimics "Missing input
  # file."), so a failing protoc is injected with a sandbox-local shim that is
  # found first on PATH
  stage
  mkdir -p "$SANDBOX/failbin"
  printf '#!/usr/bin/env bash\necho "mock protoc: exploded" >&2\nexit 7\n' > "$SANDBOX/failbin/protoc"
  chmod +x "$SANDBOX/failbin/protoc"
  PATH="$SANDBOX/failbin:$PATH"
  run bash ./compile-proto-2-go.sh protos "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mock protoc: exploded"* ]]
  [[ "$output" == *"ERROR: compile-proto-2-stubs.sh failed"* ]]
  [ ! -f "$GO_MOCK_LOG" ]
  [ ! -e "$OUT/api" ]
}

@test "go failure: a failing 'go build' aborts before the output volume is touched" {
  stage
  mkdir -p "$OUT/api"
  : > "$OUT/api/previous.pb.go"
  export GO_FAIL_MATCH=build
  run_compile protos "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: 'go build ./...' failed"* ]]
  [[ "$output" == *"ERROR: compile-stubs-2-lib.sh failed"* ]]
  # the diagnostic that tells a user which of the two offline failure modes it is
  [[ "$output" == *"GOPROXY=off"* ]]
  # the previous output is still there - nothing was wiped speculatively
  [ -f "$OUT/api/previous.pb.go" ]
  [ ! -f "$OUT/api/mock.pb.go" ]
  [ ! -f "$OUT/go.mod" ]
}

@test "go failure: the abort message goes to stderr, not stdout" {
  stage
  rm -f "$IN/protos/test.proto" "$IN/protos/dependency/myimport.proto"
  run bash -c "bash ./compile-proto-2-go.sh protos '' '$MODULE' 2>'$SANDBOX/err.txt' >'$SANDBOX/out.txt'"
  [ "$status" -ne 0 ]
  run grep -Fq "ERROR: compile-proto-2-stubs.sh failed" "$SANDBOX/err.txt"
  [ "$status" -eq 0 ]
  run grep -Fq "ERROR:" "$SANDBOX/out.txt"
  [ "$status" -ne 0 ]
}

# -------------------------------------------------------------- go.mod / go.sum

@test "go manifest: a hand-maintained go.mod in the output volume is kept and the requirements echoed" {
  stage
  printf 'module github.com/hand/written\n\ngo 1.25.0\n' > "$OUT/go.mod"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"go.mod already exists in the output volume -> keeping it"* ]]
  # instead of overwriting it the script prints what the stubs need
  [[ "$output" == *"The generated stubs require these modules"* ]]
  [[ "$output" == *"google.golang.org/grpc"* ]]
  [[ "$output" == *"google.golang.org/protobuf"* ]]
  # the generated stubs still land in the output volume - only the manifest is kept
  [ -f "$OUT/api/mock.pb.go" ]
  run grep -Fqx "module github.com/hand/written" "$OUT/go.mod"
  [ "$status" -eq 0 ]
}

@test "go manifest: the image's go.sum is staged next to the rendered go.mod and copied out" {
  stage
  printf 'google.golang.org/grpc v1.83.2 h1:image-resolved\n' \
    > "$SANDBOX/image-data/default-lib-files/go.sum"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [ -f "$TEMP_SRC/lib/go.sum" ]
  run grep -Fq "h1:image-resolved" "$OUT/go.sum"
  [ "$status" -eq 0 ]
}

@test "go manifest: a go.sum from the input repo is dropped when the image ships none" {
  stage
  printf 'github.com/client/own v1.0.0 h1:client-resolved\n' > "$IN/go.sum"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: no pre-resolved"* ]]
  # it must not survive into the build tree, where it would contradict the
  # rendered go.mod, nor be shipped to the output volume
  [ ! -f "$TEMP_SRC/go.sum" ]
  [ ! -f "$TEMP_SRC/lib/go.sum" ]
  [ ! -f "$OUT/go.sum" ]
  # the client's own copy is untouched (the mount is read-only by contract)
  run grep -Fq "h1:client-resolved" "$IN/go.sum"
  [ "$status" -eq 0 ]
}

@test "go manifest: a missing go.mod.template fails loudly" {
  stage
  rm -f "$SANDBOX/image-data/default-lib-files/go.mod.template"
  run_compile protos "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"go.mod.template is missing"* ]]
  [ ! -f "$GO_MOCK_LOG" ]
  [ ! -e "$OUT/api" ]
}

@test "go manifest: a go.mod.template without the @GO_MODULE_PATH@ placeholder fails loudly" {
  stage
  printf 'module ondewo.local/warmup\n\ngo 1.25.0\n' \
    > "$SANDBOX/image-data/default-lib-files/go.mod.template"
  run_compile protos "" "$MODULE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"carries no @GO_MODULE_PATH@ placeholder"* ]]
  [ ! -f "$GO_MOCK_LOG" ]
}

@test "go manifest: the image go.sum is not written beside a kept hand-maintained go.mod" {
  stage
  printf 'google.golang.org/grpc v1.83.2 h1:image-resolved\n' \
    > "$SANDBOX/image-data/default-lib-files/go.sum"
  printf 'module github.com/hand/written\n\ngo 1.25.0\nrequire github.com/client/own v1.0.0\n' \
    > "$OUT/go.mod"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [ ! -f "$OUT/go.sum" ]
}

# ---------------------------------------------------- sub-scripts, called alone

@test "go stubs: the argument guard reports usage" {
  run bash "$REPO_ROOT/go/image-data/compile-proto-2-stubs.sh" "$SANDBOX/api" "$IN/protos"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-proto-2-stubs.sh"* ]]
  [ ! -f "$PROTOC_MOCK_LOG" ]
}

@test "go stubs: a nonexistent protos root fails loudly" {
  run bash "$REPO_ROOT/go/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/api" "$SANDBOX/nope" "$SANDBOX/nope" "$MODULE/api"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the protos root directory"* ]]
  [[ "$output" == *"does not exist"* ]]
}

@test "go stubs: the stubs target dir is wiped before generation" {
  mkdir -p "$SANDBOX/api/old"
  : > "$SANDBOX/api/old/orphan.pb.go"
  run bash "$REPO_ROOT/go/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/api" "$IN/protos" "$IN/protos" "$MODULE/api"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/api/old" ]
  [ -f "$SANDBOX/api/mock.pb.go" ]
  [ -f "$SANDBOX/api/mock_grpc.pb.go" ]
}

@test "go lib: the argument guard reports usage" {
  run bash "$REPO_ROOT/go/image-data/compile-stubs-2-lib.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-stubs-2-lib.sh"* ]]
  [ ! -f "$GO_MOCK_LOG" ]
}

@test "go lib: a missing go.mod fails loudly instead of building the wrong module" {
  mkdir -p "$SANDBOX/src/api"
  : > "$SANDBOX/src/api/mock.pb.go"
  run bash "$REPO_ROOT/go/image-data/compile-stubs-2-lib.sh" "$SANDBOX/src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no go.mod in"* ]]
  [ ! -f "$GO_MOCK_LOG" ]
}

@test "go lib: missing generated stubs fail loudly" {
  mkdir -p "$SANDBOX/src"
  printf 'module github.com/x/y\n' > "$SANDBOX/src/go.mod"
  run bash "$REPO_ROOT/go/image-data/compile-stubs-2-lib.sh" "$SANDBOX/src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no generated stubs in"* ]]
  [[ "$output" == *"compile-proto-2-stubs.sh has to run first"* ]]
  [ ! -f "$GO_MOCK_LOG" ]
}

@test "go lib: the staging dir is rebuilt from scratch on every run" {
  mkdir -p "$SANDBOX/src/api" "$SANDBOX/src/lib/api"
  printf 'module github.com/x/y\n' > "$SANDBOX/src/go.mod"
  : > "$SANDBOX/src/api/mock.pb.go"
  : > "$SANDBOX/src/lib/api/orphan.pb.go"
  : > "$SANDBOX/src/lib/leftover.txt"
  run bash "$REPO_ROOT/go/image-data/compile-stubs-2-lib.sh" "$SANDBOX/src"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/src/lib/leftover.txt" ]
  [ ! -e "$SANDBOX/src/lib/api/orphan.pb.go" ]
  [ -f "$SANDBOX/src/lib/api/mock.pb.go" ]
  [ -f "$SANDBOX/src/lib/go.mod" ]
  run grep -Fqx 'go build ./...' "$GO_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "go lib: a custom stubs sub-directory is honoured" {
  mkdir -p "$SANDBOX/src/stubs"
  printf 'module github.com/x/y\n' > "$SANDBOX/src/go.mod"
  : > "$SANDBOX/src/stubs/mock.pb.go"
  run bash "$REPO_ROOT/go/image-data/compile-stubs-2-lib.sh" "$SANDBOX/src" stubs
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/src/lib/stubs/mock.pb.go" ]
  [ ! -e "$SANDBOX/src/lib/api" ]
}

# --------------------------------------------------------------- env overrides

@test "go env: TEMP_SRC_DIRECTORY redirects the scratch copy away from the default" {
  stage
  export TEMP_SRC_DIRECTORY="$SANDBOX/elsewhere"
  run_compile protos "" "$MODULE"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/elsewhere/protos/test.proto" ]
  [ -d "$SANDBOX/elsewhere/lib/api" ]
  [ ! -e "$SANDBOX/image-data/src" ]
  [ -f "$OUT/api/mock.pb.go" ]
}

# --------------------------------------------- example + Makefile entry points
# (examples.bats already covers the mount shape / -it / quoting for every target;
#  what is go-specific is the THIRD entrypoint argument, the module path, without
#  which the image refuses to run at all.)

@test "go example: run-compile passes a module path the entrypoint accepts" {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  mkdir -p "$SANDBOX/example"
  cp "$REPO_ROOT/go/example/run-compile.sh" "$SANDBOX/example/run.sh"
  run bash "$SANDBOX/example/run.sh"
  [ "$status" -eq 0 ]
  run grep -Fq -- "ondewo-go-proto-compiler protos" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  # 3rd positional argument of the entrypoint; empty target sub-dir in between
  module="$(sed -n 's|.*ondewo-go-proto-compiler protos  *\([^ ][^ ]*\).*|\1|p' "$DOCKER_MOCK_LOG")"
  [ -n "$module" ]
  # ... and the orchestrator really accepts it (no whitespace, no leading '/')
  stage
  run_compile protos "" "$module"
  [ "$status" -eq 0 ]
  run grep -Fqx "module $module" "$OUT/go.mod"
  [ "$status" -eq 0 ]
}

@test "go make: the run target refuses to start without GO_MODULE_PATH" {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  mkdir -p "$SANDBOX/mk/example/protos"
  cp "$REPO_ROOT/go/Makefile" "$SANDBOX/mk/Makefile"
  cd "$SANDBOX/mk"
  run make run
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: GO_MODULE_PATH is required"* ]]
  [ ! -f "$DOCKER_MOCK_LOG" ]
}

@test "go make: the run target mounts protos in, lib out and passes the module path" {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  mkdir -p "$SANDBOX/mk/example/protos"
  cp "$REPO_ROOT/go/Makefile" "$SANDBOX/mk/Makefile"
  cd "$SANDBOX/mk"
  run make run GO_MODULE_PATH=github.com/x/y
  [ "$status" -eq 0 ]
  run grep -Fq -- "-v $SANDBOX/mk/example/protos:/input-volume/protos" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "-v $SANDBOX/mk/example/lib:/output-volume" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "ondewo-go-proto-compiler protos  github.com/x/y" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/mk/example/lib" ]
  # no -it (breaks non-interactive callers) and no --user (the go caches are root-owned)
  run grep -Eq -- '(^|[[:space:]])(-it|-ti)([[:space:]]|$)' "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
  run grep -Fq -- "--user" "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "go offline: the image forbids any network access at generation time" {
  # CONTRACT §9: everything the package build needs is pre-warmed at image build
  # time and the run-time build is put into its offline mode, so a cache miss
  # fails loudly instead of silently fetching.
  for flag in "GOPROXY=off" "GOFLAGS=-mod=readonly" "GOTOOLCHAIN=local"; do
    run grep -Fq "$flag" "$REPO_ROOT/go/Dockerfile"
    [ "$status" -eq 0 ]
  done
}
