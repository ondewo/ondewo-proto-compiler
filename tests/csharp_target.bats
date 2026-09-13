#!/usr/bin/env bats
# End-to-end and unit coverage for the `csharp/` proto-compiler target, driven on
# the HOST: the container paths (/image-data, /input-volume, /output-volume,
# /image-data/src) are overridden through the env knobs the scripts expose, and
# the toolchain (protoc, dotnet) is PATH-mocked. No docker build, no network, no
# real .NET SDK.
#
# What is pinned here
#   * the orchestrator pipeline: input copied to the compile dir and never
#     mutated, stubs generated, package restored/built/packed offline, the
#     documented layout copied back to the output volume
#   * the output-volume fallback to <input>/lib
#   * stale-output cleanup (api/, artifacts/, nupkg/) and what must survive it,
#     plus the wipe of the stubs target api/ inside the compile directory
#   * argument handling: default protos dir, explicit protos dir, target subdir
#   * the protoc command line: single -I root, --csharp_out/--grpc_out,
#     base_namespace=, the grpc plugin flag
#   * the EXTRA protoc -I roots: the googleapis/ auto-detection that makes
#     ondewo-survey-api's vendored google/* imports resolvable, that it stays
#     off for every root that already resolves them, and the EXTRA_PROTO_DIRS
#     override
#   * failure propagation from both sub-scripts, with the orchestrator's own
#     error text on stderr
#   * package identity resolution + validation, the five required MSBuild
#     properties, and the placeholder substitution in nuget.config
#
# The grpc_csharp_plugin binary is never exec'd by these scripts (protoc runs
# it) and, unlike cpp, is not `command -v`-guarded either, so no mock of that
# name is required - only the flag spelling is asserted.

load 'helpers/setup'

setup() {
  common_setup
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  export DOTNET_MOCK_LOG="$SANDBOX/dotnet.log"

  IN="$SANDBOX/input"
  OUT="$SANDBOX/output"
  TMPSRC="$SANDBOX/temp-src"
  FEED="$SANDBOX/offline-feed"
  PLUGIN="$SANDBOX/bin/grpc_csharp_plugin"
  DEFAULTS="$REPO_ROOT/csharp/image-data/default-lib-files"

  mkdir -p "$IN/protos/library/dependency" "$IN/protos/other" "$OUT" "$FEED"
  printf 'syntax = "proto3";\npackage example;\noption csharp_namespace = "Ondewo.Example";\nimport "library/dependency/myimport.proto";\nmessage Test { string name = 1; }\nservice SimpleService { rpc SendTest (Test) returns (Test); }\n' \
    > "$IN/protos/library/test.proto"
  printf 'syntax = "proto3";\npackage dependency;\noption csharp_namespace = "Ondewo.Example.Dependency";\nmessage MyImport { string name = 1; }\n' \
    > "$IN/protos/library/dependency/myimport.proto"
  printf 'syntax = "proto3";\npackage other;\noption csharp_namespace = "Ondewo.Other";\nmessage Other { string name = 1; }\n' \
    > "$IN/protos/other/other.proto"
}

teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Copy the target's image-data into the sandbox (nothing is ever written into
# the repo tree), cd there (the orchestrator invokes its siblings as ./x.sh) and
# point every container path at the sandbox.
stage() {
  cp -r "$REPO_ROOT/csharp/image-data" "$SANDBOX/image-data"
  cd "$SANDBOX/image-data"
  export IMAGE_DATA_DIRECTORY="$SANDBOX/image-data"
  export INPUT_VOLUME_FS="$IN"
  export OUTPUT_VOLUME_FS="$OUT"
  export TEMP_SRC_DIRECTORY="$TMPSRC"
  subscript_env
}

# The knobs the image supplies as MSBuild properties / paths. common_setup
# scrubs the NUGET_*, GRPC_* and Ondewo* namespaces, so they are (re)set here,
# after it has run.
subscript_env() {
  # not in any namespace common_setup scrubs, and an ambient value would add an
  # -I root (or abort the run) on the developer's machine only
  unset EXTRA_PROTO_DIRS
  export NUGET_OFFLINE_FEED="$FEED"
  export GRPC_CSHARP_PLUGIN="$PLUGIN"
  export OndewoTargetFramework=netstandard2.0
  export OndewoPackageVersion=5.14.0
  export GoogleProtobufVersion=3.32.0
  export GrpcDotnetVersion=2.83.0
  export GoogleApiCommonProtosVersion=2.17.0
}

# how often an exact whitespace-delimited token appears in the protoc log
protoc_token_count() {
  tr ' ' '\n' < "$PROTOC_MOCK_LOG" | grep -c "^$1\$" || true
}

# number of logged invocations (one line per call)
log_lines() {
  grep -c . "$1" 2>/dev/null || true
}

# assert the protoc log does NOT mention a path fragment
refute_protoc_arg() {
  run grep -Fq -- "$1" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

assert_protoc_arg() {
  run grep -Fq -- "$1" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

# Install a purpose-built `protoc` ahead of the shared PATH mock for ONE test
# (the shared mock always succeeds and always writes the same tree). The script
# body is read from stdin, so the caller writes it as a heredoc.
shadow_protoc() {
  mkdir -p "$SANDBOX/shadow-bin"
  cat > "$SANDBOX/shadow-bin/protoc"
  chmod +x "$SANDBOX/shadow-bin/protoc"
  PATH="$SANDBOX/shadow-bin:$PATH"
  export PATH
}

# Same for `dotnet`: the shared mock always materialises bin/Release/<tfm>, so a
# build that succeeds while putting its assemblies somewhere else needs its own.
shadow_dotnet() {
  mkdir -p "$SANDBOX/shadow-bin"
  cat > "$SANDBOX/shadow-bin/dotnet"
  chmod +x "$SANDBOX/shadow-bin/dotnet"
  PATH="$SANDBOX/shadow-bin:$PATH"
  export PATH
}

# A `dotnet` that honours the .NET 8 artifacts layout (<UseArtifactsOutput>, as a
# client-supplied Directory.Build.props can switch on): restore/build/pack all
# succeed, the assembly lands in artifacts/bin/<id>/release/ and the .nupkg in
# the -o directory - so the conventional bin/Release is never created.
shadow_dotnet_artifacts_layout() {
  shadow_dotnet <<'MOCK'
#!/usr/bin/env bash
: "${DOTNET_MOCK_LOG:=/dev/null}"
printf 'dotnet %s\n' "$*" >> "$DOTNET_MOCK_LOG"

verb=$1
shift
project=""
out_dir=""
want_out=0
for a in "$@"; do
  if [ "$want_out" -eq 1 ]; then
    out_dir=$a
    want_out=0
    continue
  fi
  case "$a" in
    -o|--output) want_out=1 ;;
    -*) ;;
    *) [ -n "$project" ] || project=$a ;;
  esac
done
project_dir=$(dirname "$project")
package_id=$(basename "$project" .csproj)

case "$verb" in
  build)
    mkdir -p "$project_dir/artifacts/bin/$package_id/release"
    : > "$project_dir/artifacts/bin/$package_id/release/$package_id.dll"
    ;;
  pack)
    [ -n "$out_dir" ] || out_dir="$project_dir/artifacts/package/release"
    mkdir -p "$out_dir"
    : > "$out_dir/$package_id.nupkg"
    ;;
esac
echo "mock dotnet $verb (artifacts layout): OK"
exit 0
MOCK
}

# ---------------------------------------------------------------------------
# orchestrator, happy path
# ---------------------------------------------------------------------------

@test "csharp e2e: the full pipeline writes the documented layout to the output volume" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]

  # generated stubs, nested by C# namespace (what base_namespace= produces)
  [ -f "$OUT/api/Ondewo/Mock/Test.cs" ]
  [ -f "$OUT/api/Ondewo/Mock/TestGrpc.cs" ]
  # assembly + symbols + XML docs, keeping the per-target-framework sub-dir
  [ -f "$OUT/artifacts/netstandard2.0/Ondewo.Test.Client.dll" ]
  [ -f "$OUT/artifacts/netstandard2.0/Ondewo.Test.Client.pdb" ]
  [ -f "$OUT/artifacts/netstandard2.0/Ondewo.Test.Client.xml" ]
  # the distributable package pair
  [ -f "$OUT/nupkg/Ondewo.Test.Client.5.14.0.nupkg" ]
  [ -f "$OUT/nupkg/Ondewo.Test.Client.5.14.0.snupkg" ]
  # so a client repo can rebuild the package itself
  [ -f "$OUT/Ondewo.Test.Client.csproj" ]
}

@test "csharp e2e: bin/, obj/, README.md and nuget.config are deliberately not copied out" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]

  # they exist in the internal compile directory ...
  [ -d "$TMPSRC/bin/Release" ]
  [ -d "$TMPSRC/obj" ]
  [ -f "$TMPSRC/README.md" ]
  [ -f "$TMPSRC/nuget.config" ]
  # ... and must never reach the client's repository root
  [ ! -e "$OUT/bin" ]
  [ ! -e "$OUT/obj" ]
  [ ! -e "$OUT/README.md" ]
  [ ! -e "$OUT/nuget.config" ]
}

@test "csharp e2e: the mounted input volume is never mutated" {
  cp -r "$IN" "$SANDBOX/input.pristine"
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]

  run diff -r "$SANDBOX/input.pristine" "$IN"
  echo "$output"
  [ "$status" -eq 0 ]
  # specifically: no build output and no generated tree in the mount
  [ ! -e "$IN/api" ]
  [ ! -e "$IN/bin" ]
  [ ! -e "$IN/obj" ]
  [ ! -e "$IN/lib" ]
  [ ! -e "$IN/nuget.config" ]
}

@test "csharp e2e: two consecutive container runs against the same output volume agree" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]
  ( cd "$OUT" && find . | sort ) > "$SANDBOX/run1.txt"

  # a second run is a second container: a fresh compile directory
  export TEMP_SRC_DIRECTORY="$SANDBOX/temp-src-2"
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]
  ( cd "$OUT" && find . | sort ) > "$SANDBOX/run2.txt"

  run diff "$SANDBOX/run1.txt" "$SANDBOX/run2.txt"
  echo "$output"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# output volume fallback
# ---------------------------------------------------------------------------

@test "csharp: a missing output volume falls back to <input-volume>/lib" {
  stage
  export OUTPUT_VOLUME_FS="$SANDBOX/no-such-output"
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"creating output in sourcevolume/lib directory"* ]]

  [ -f "$IN/lib/api/Ondewo/Mock/Test.cs" ]
  [ -f "$IN/lib/Ondewo.Test.Client.csproj" ]
  [ -d "$IN/lib/nupkg" ]
  # the non-existent path is never created
  [ ! -e "$SANDBOX/no-such-output" ]
}

@test "csharp: an output volume nested inside the input volume (the example layout) works twice" {
  stage
  export OUTPUT_VOLUME_FS="$IN/lib"
  mkdir -p "$IN/lib"

  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]
  [ -f "$IN/lib/api/Ondewo/Mock/Test.cs" ]

  # the second run copies run 1's lib/ into the compile directory;
  # compile-stubs-2-lib.sh must wipe it so nothing is nested or compiled twice
  export TEMP_SRC_DIRECTORY="$SANDBOX/temp-src-2"
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$IN/lib/lib" ]
  [ -f "$IN/lib/api/Ondewo/Mock/Test.cs" ]
}

# ---------------------------------------------------------------------------
# stale output cleanup
# ---------------------------------------------------------------------------

@test "csharp: stale stubs/artifacts/packages from a previous run do not survive" {
  mkdir -p "$OUT/api/Ondewo/Mock" "$OUT/artifacts/netstandard2.0" "$OUT/nupkg"
  : > "$OUT/api/Ondewo/Mock/DeletedProto.cs"
  : > "$OUT/artifacts/netstandard2.0/Ondewo.Old.Client.dll"
  : > "$OUT/nupkg/Ondewo.Old.Client.1.0.0.nupkg"

  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]

  [ ! -e "$OUT/api/Ondewo/Mock/DeletedProto.cs" ]
  [ ! -e "$OUT/artifacts/netstandard2.0/Ondewo.Old.Client.dll" ]
  [ ! -e "$OUT/nupkg/Ondewo.Old.Client.1.0.0.nupkg" ]
  [ -f "$OUT/api/Ondewo/Mock/Test.cs" ]
  [ -f "$OUT/nupkg/Ondewo.Test.Client.5.14.0.nupkg" ]
}

@test "csharp: the output volume's own bin/, obj/ and README.md survive the cleanup" {
  mkdir -p "$OUT/bin" "$OUT/obj"
  printf 'client build output\n' > "$OUT/bin/keep.txt"
  printf 'client intermediates\n' > "$OUT/obj/keep.txt"
  printf '# the client repository readme\n' > "$OUT/README.md"

  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]

  run grep -Fq 'client build output' "$OUT/bin/keep.txt"
  [ "$status" -eq 0 ]
  run grep -Fq 'client intermediates' "$OUT/obj/keep.txt"
  [ "$status" -eq 0 ]
  run grep -Fq 'the client repository readme' "$OUT/README.md"
  [ "$status" -eq 0 ]
}

@test "csharp: a previous run's lib/ inside the input volume is not shipped to the output" {
  mkdir -p "$IN/lib"
  : > "$IN/lib/stale-artifact.txt"

  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]

  # lib/ is copied into the compile dir, then emptied before the build
  [ ! -e "$OUT/stale-artifact.txt" ]
  [ -f "$OUT/api/Ondewo/Mock/Test.cs" ]
}

@test "csharp: a previous run's api/ inside the input volume is not shipped to the output" {
  # api/ is the stubs target INSIDE the compile directory, and the compile
  # directory is a verbatim copy of the input volume - which for a C# client is
  # the repository itself, api/ and all. Without a wipe (the api/ half of what
  # compile-stubs-2-lib.sh does for lib/) the stub of a proto that was renamed or
  # deleted is compiled into the assembly and copied back out for ever.
  mkdir -p "$IN/api/Ondewo/Old"
  : > "$IN/api/Ondewo/Old/Removed.cs"

  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]

  # gone from the compile directory before protoc runs ...
  [ ! -e "$TMPSRC/api/Ondewo/Old/Removed.cs" ]
  # ... so it reaches neither the packaged library nor the output volume
  [ ! -e "$OUT/api/Ondewo/Old/Removed.cs" ]
  [ -f "$OUT/api/Ondewo/Mock/Test.cs" ]
  # and the mount itself is still untouched
  [ -f "$IN/api/Ondewo/Old/Removed.cs" ]
}

@test "csharp: a regular FILE named api in the input volume does not block generation" {
  # same wipe, degenerate shape: the copied-in file would make the stubs target
  # directory un-creatable
  printf 'not a directory\n' > "$IN/api"

  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$OUT/api/Ondewo/Mock/Test.cs" ]

  # the mount keeps its file
  run grep -Fq 'not a directory' "$IN/api"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# argument handling
# ---------------------------------------------------------------------------

@test "csharp args: no arguments at all use the 'protos' default and the default package id" {
  stage
  run bash ./compile-proto-2-csharp.sh
  echo "$output"
  [ "$status" -eq 0 ]

  assert_protoc_arg "-I $IN/protos "
  assert_protoc_arg "$IN/protos/library/test.proto"
  [ -f "$OUT/Ondewo.Grpc.Client.csproj" ]
  [ -f "$OUT/nupkg/Ondewo.Grpc.Client.5.14.0.nupkg" ]
}

@test "csharp args: an explicit relative protos dir becomes the protoc -I root" {
  mkdir -p "$IN/ondewo-nlu-api/ondewo/nlu"
  printf 'syntax = "proto3";\npackage ondewo.nlu;\nmessage S {}\n' \
    > "$IN/ondewo-nlu-api/ondewo/nlu/session.proto"

  stage
  run bash ./compile-proto-2-csharp.sh ondewo-nlu-api "" Ondewo.Nlu.Client
  echo "$output"
  [ "$status" -eq 0 ]

  assert_protoc_arg "-I $IN/ondewo-nlu-api "
  assert_protoc_arg "$IN/ondewo-nlu-api/ondewo/nlu/session.proto"
  # the default root is NOT used
  refute_protoc_arg "$IN/protos/library/test.proto"
}

@test "csharp args: the target subdir scopes compilation to one sub-tree" {
  stage
  run bash ./compile-proto-2-csharp.sh protos library Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]

  # -I stays the proto ROOT even though only a sub-tree is compiled
  assert_protoc_arg "-I $IN/protos "
  assert_protoc_arg "$IN/protos/library/test.proto"
  assert_protoc_arg "$IN/protos/library/dependency/myimport.proto"
  refute_protoc_arg "$IN/protos/other/other.proto"
}

@test "csharp args: an empty target subdir compiles every proto below the root" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]

  assert_protoc_arg "$IN/protos/library/test.proto"
  assert_protoc_arg "$IN/protos/library/dependency/myimport.proto"
  assert_protoc_arg "$IN/protos/other/other.proto"
}

@test "csharp args: a non-existent target subdir aborts before the package is built" {
  stage
  run bash ./compile-proto-2-csharp.sh protos nosuchdir Ondewo.Test.Client
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protos source directory"*"does not exist"* ]]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]
  [ ! -s "$DOTNET_MOCK_LOG" ]
}

# ---------------------------------------------------------------------------
# the protoc command line
# ---------------------------------------------------------------------------

@test "csharp protoc: one invocation with the csharp/grpc out flags, base_namespace and the plugin" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]

  [ "$(log_lines "$PROTOC_MOCK_LOG")" -eq 1 ]
  assert_protoc_arg "--plugin=protoc-gen-grpc=$PLUGIN "
  assert_protoc_arg "--csharp_out=$TMPSRC/api "
  # the EMPTY base_namespace value is load-bearing: it nests the output by C#
  # namespace instead of writing flat, colliding basenames
  assert_protoc_arg "--csharp_opt=base_namespace= "
  # --grpc_out has to carry the option in the "opts:DIR" form
  assert_protoc_arg "--grpc_out=base_namespace=:$TMPSRC/api "
}

@test "csharp protoc: exactly one -I root and no google/protobuf include path" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]

  # the well-known types resolve from protoc's own <bindir>/../include, so the
  # script must not add a second -I (nor a --proto_path) for them
  [ "$(protoc_token_count '-I')" -eq 1 ]
  assert_protoc_arg "-I $IN/protos "
  [ "$(protoc_token_count '--proto_path')" -eq 0 ]
  refute_protoc_arg "google/protobuf"
  # and there is no 4th proto-deps argument the way the node targets have one
  [ ! -e "$TMPSRC/proto-deps.txt" ]
}

@test "csharp protoc: GRPC_CSHARP_PLUGIN defaults to the container path when unset" {
  stage
  unset GRPC_CSHARP_PLUGIN
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]
  assert_protoc_arg "--plugin=protoc-gen-grpc=/usr/local/bin/grpc_csharp_plugin "
}

@test "csharp protoc: stubs land under the internal compile dir, never in the input volume" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]
  [ -f "$TMPSRC/api/Ondewo/Mock/Test.cs" ]
  [ ! -e "$IN/protos/api" ]
  [ ! -e "$IN/api" ]
}

@test "csharp protoc: google/** vendored under the protos root is NOT code-generated" {
  # The script's own header states 'no google/* stubs are generated here' (the
  # descriptors ship in the Google.Api.CommonProtos / Google.Protobuf NuGet
  # packages the .csproj references). Without the `! -path "*/google/*"` filter
  # on ALL_PROTO_FILES, the documented-optional empty target subdir - which is
  # what csharp/Makefile's `make run` and csharp/example/run-compile.sh both
  # pass - sweeps every google/** proto vendored in the client's proto root
  # (ondewo-nlu-api ships google/api, google/rpc, google/type, google/ads,
  # google/cloud, ...) into the same assembly, duplicating the NuGet-supplied
  # types.
  mkdir -p "$IN/protos/google/api" "$IN/protos/google/protobuf"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Http {}\n' \
    > "$IN/protos/google/api/annotations.proto"
  printf 'syntax = "proto3";\npackage google.protobuf;\nmessage Empty {}\n' \
    > "$IN/protos/google/protobuf/empty.proto"

  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]

  refute_protoc_arg "google/api/annotations.proto"
  refute_protoc_arg "google/protobuf/empty.proto"
}

# ---------------------------------------------------------------------------
# extra protoc -I roots (the ondewo-survey-api layout)
# ---------------------------------------------------------------------------

# ondewo-survey-api does not vendor its google/* imports at the proto root the
# way nlu/csi/vtsi do: it carries a whole googleapis/ checkout, so the very same
# `import "google/api/annotations.proto";` lives one level deeper and protoc
# cannot resolve it from -I <root> alone.
make_survey_layout() {
  mkdir -p "$IN/ondewo-survey-api/ondewo/survey" \
           "$IN/ondewo-survey-api/googleapis/google/api"
  printf 'syntax = "proto3";\npackage ondewo.survey;\nimport "google/api/annotations.proto";\nmessage Survey { string name = 1; }\nservice Surveys { rpc GetSurvey (Survey) returns (Survey); }\n' \
    > "$IN/ondewo-survey-api/ondewo/survey/survey.proto"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Http {}\n' \
    > "$IN/ondewo-survey-api/googleapis/google/api/annotations.proto"
}

@test "csharp extra -I: a nested googleapis/ root is auto-detected and added as a second -I" {
  make_survey_layout
  stage
  run bash ./compile-proto-2-csharp.sh ondewo-survey-api ondewo Ondewo.Survey.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected a nested googleapis/ layout in '$IN/ondewo-survey-api'"* ]]
  [[ "$output" == *"Using extra proto include root: $IN/ondewo-survey-api/googleapis"* ]]

  # the proto ROOT stays the first -I; the googleapis checkout is added on top
  [ "$(protoc_token_count '-I')" -eq 2 ]
  assert_protoc_arg "-I $IN/ondewo-survey-api "
  assert_protoc_arg "-I $IN/ondewo-survey-api/googleapis "
  # and the run really produces a package
  [ -f "$OUT/api/Ondewo/Mock/Test.cs" ]
  [ -f "$OUT/nupkg/Ondewo.Survey.Client.5.14.0.nupkg" ]
}

@test "csharp extra -I: the extra root is an IMPORT path, never a compilation target" {
  # The google/** exclusion has to keep holding one level deeper, otherwise the
  # documented-optional empty target subdir sweeps the ~440 vendored googleapis
  # protos into the assembly, duplicating the NuGet-supplied Google.* types.
  make_survey_layout
  stage
  run bash ./compile-proto-2-csharp.sh ondewo-survey-api "" Ondewo.Survey.Client
  echo "$output"
  [ "$status" -eq 0 ]

  assert_protoc_arg "-I $IN/ondewo-survey-api/googleapis "
  assert_protoc_arg "$IN/ondewo-survey-api/ondewo/survey/survey.proto"
  refute_protoc_arg "googleapis/google/api/annotations.proto"
}

@test "csharp extra -I: a root that vendors google/ itself keeps its single -I" {
  # every product except survey (nlu, csi, vtsi, ...): nothing may change for them
  mkdir -p "$IN/ondewo-nlu-api/ondewo/nlu" "$IN/ondewo-nlu-api/google/api"
  printf 'syntax = "proto3";\npackage ondewo.nlu;\nmessage S {}\n' \
    > "$IN/ondewo-nlu-api/ondewo/nlu/session.proto"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Http {}\n' \
    > "$IN/ondewo-nlu-api/google/api/annotations.proto"

  stage
  run bash ./compile-proto-2-csharp.sh ondewo-nlu-api ondewo Ondewo.Nlu.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"extra proto include root"* ]]
  [ "$(protoc_token_count '-I')" -eq 1 ]
  assert_protoc_arg "-I $IN/ondewo-nlu-api "
}

@test "csharp extra -I: a root with BOTH google/ and googleapis/ keeps its single -I" {
  # the auto-detection is deliberately conservative: a root that already resolves
  # its imports is left exactly as it was, whatever else sits next to it
  make_survey_layout
  mkdir -p "$IN/ondewo-survey-api/google/api"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Http {}\n' \
    > "$IN/ondewo-survey-api/google/api/annotations.proto"

  stage
  run bash ./compile-proto-2-csharp.sh ondewo-survey-api ondewo Ondewo.Survey.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"extra proto include root"* ]]
  [ "$(protoc_token_count '-I')" -eq 1 ]
  refute_protoc_arg "-I $IN/ondewo-survey-api/googleapis "
}

@test "csharp extra -I: the default fixture (no googleapis/, no google/) stays at one -I" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]
  [[ "$output" != *"extra proto include root"* ]]
  [ "$(protoc_token_count '-I')" -eq 1 ]
}

@test "csharp extra -I: EXTRA_PROTO_DIRS overrides the auto-detection" {
  make_survey_layout
  mkdir -p "$IN/vendor-protos/google/api"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Http {}\n' \
    > "$IN/vendor-protos/google/api/annotations.proto"

  stage
  export EXTRA_PROTO_DIRS="$IN/vendor-protos"
  run bash ./compile-proto-2-csharp.sh ondewo-survey-api ondewo Ondewo.Survey.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using extra proto include root: $IN/vendor-protos"* ]]
  # the override replaces the auto-detected root, it is not added to it
  [[ "$output" != *"Detected a nested googleapis/ layout"* ]]
  [ "$(protoc_token_count '-I')" -eq 2 ]
  assert_protoc_arg "-I $IN/vendor-protos "
  refute_protoc_arg "-I $IN/ondewo-survey-api/googleapis "
}

@test "csharp extra -I: EXTRA_PROTO_DIRS takes a space-separated list of roots" {
  mkdir -p "$IN/vendor-a/google/api" "$IN/vendor-b/google/rpc"

  stage
  export EXTRA_PROTO_DIRS="$IN/vendor-a $IN/vendor-b"
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(protoc_token_count '-I')" -eq 3 ]
  assert_protoc_arg "-I $IN/protos "
  assert_protoc_arg "-I $IN/vendor-a "
  assert_protoc_arg "-I $IN/vendor-b "
}

@test "csharp extra -I: a non-existent EXTRA_PROTO_DIRS entry aborts before protoc runs" {
  # otherwise it surfaces as protoc's generic "File not found." for whichever
  # import the include root was meant to satisfy
  stage
  export EXTRA_PROTO_DIRS="$IN/no-such-vendor"
  run bash -c 'bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client 2>&1 >/dev/null'
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"extra proto include directory '$IN/no-such-vendor' does not exist"* ]]
  [[ "$output" == *"EXTRA_PROTO_DIRS"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$DOTNET_MOCK_LOG" ]
}

@test "csharp extra -I: the stubs script auto-detects from the -I root it is handed" {
  # driven directly, without the orchestrator: the detection is anchored on
  # <protos_root_dir>, not on the input volume or the compile directory
  make_survey_layout
  subscript_env
  run bash "$REPO_ROOT/csharp/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/stubs-out" "$IN/ondewo-survey-api" "$IN/ondewo-survey-api/ondewo"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using extra proto include root: $IN/ondewo-survey-api/googleapis"* ]]
  assert_protoc_arg "-I $IN/ondewo-survey-api/googleapis "
  [ -f "$SANDBOX/stubs-out/Ondewo/Mock/Test.cs" ]
}

# ---------------------------------------------------------------------------
# failure propagation
# ---------------------------------------------------------------------------

@test "csharp failure: compile-proto-2-stubs.sh failing aborts the orchestrator" {
  stage
  # protoc itself fails (a bad import, an unknown option, a plugin crash)
  shadow_protoc <<'MOCK'
#!/usr/bin/env bash
echo "mock protoc: cannot generate" >&2
exit 1
MOCK
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]
  [ ! -s "$DOTNET_MOCK_LOG" ]
  [ ! -e "$OUT/api" ]
}

@test "csharp failure: dotnet restore failing aborts with the offline-feed hint" {
  stage
  export DOTNET_FAIL_MATCH=restore
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dotnet restore of"* ]]
  [[ "$output" == *"$FEED"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
  # nothing was copied back
  [ ! -e "$OUT/api" ]
  [ ! -e "$OUT/nupkg" ]
}

@test "csharp failure: dotnet build failing aborts the orchestrator" {
  stage
  export DOTNET_FAIL_MATCH=build
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dotnet build of"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
  [ ! -e "$OUT/api" ]
}

@test "csharp failure: dotnet pack failing aborts the orchestrator" {
  stage
  export DOTNET_FAIL_MATCH=pack
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dotnet pack of"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
  [ ! -e "$OUT/nupkg" ]
}

@test "csharp failure: a successful build that produces no bin/Release aborts the orchestrator" {
  stage
  shadow_dotnet_artifacts_layout
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dotnet build produced no '$TMPSRC/bin/Release' output directory"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
  # the failure is the collection step, not a dotnet call: all three ran
  [ "$(log_lines "$DOTNET_MOCK_LOG")" -eq 3 ]
  # nothing reached the output volume, and the success banner never printed
  [ ! -e "$OUT/api" ]
  [ ! -e "$OUT/artifacts" ]
  [ ! -e "$OUT/nupkg" ]
  [ ! -e "$OUT/Ondewo.Test.Client.csproj" ]
  [[ "$output" != *"✅"* ]]
}

@test "csharp failure: the orchestrator's abort messages go to stderr" {
  stage
  export DOTNET_FAIL_MATCH=restore
  run bash -c 'bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client 2>&1 >/dev/null'
  [ "$status" -ne 0 ]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
}

@test "csharp failure: a missing input volume fails loudly on stderr" {
  stage
  export INPUT_VOLUME_FS="$SANDBOX/no-such-input"
  run bash -c 'bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client 2>&1 >/dev/null'
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"input volume"*"does not exist"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$DOTNET_MOCK_LOG" ]
}

# ---------------------------------------------------------------------------
# the no-protos guard
# ---------------------------------------------------------------------------

@test "csharp guard: an empty protos dir fails loudly and never builds the package" {
  rm -rf "$IN/protos"
  mkdir -p "$IN/protos"
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found in"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$DOTNET_MOCK_LOG" ]
  [ ! -e "$OUT/api" ]
}

@test "csharp guard: a DIRECTORY named *.proto does not satisfy the no-protos check" {
  # Without `-type f` PROTO_FILES_CNT would count a DIRECTORY whose name ends in
  # .proto as an input and then hand it to protoc as a positional argument: the
  # guard that exists to stop a run with no compilable protos would let it
  # through, and the failure would be reported by protoc ("Is a directory")
  # instead of by the script's own message. The sibling new targets rust and java
  # both use `find ... -type f -iname` too.
  rm -rf "$IN/protos"
  mkdir -p "$IN/protos/not-a-file.proto"
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found in"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "csharp guard: a missing protos dir fails loudly and never builds the package" {
  stage
  run bash ./compile-proto-2-csharp.sh no-such-protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protos source directory"*"does not exist"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$DOTNET_MOCK_LOG" ]
}

# ---------------------------------------------------------------------------
# package identity
# ---------------------------------------------------------------------------

@test "csharp package id: an invalid id is rejected before anything is copied or generated" {
  stage
  run bash -c 'bash ./compile-proto-2-csharp.sh protos "" "Bad Id" 2>&1 >/dev/null'
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid package id 'Bad Id'"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$DOTNET_MOCK_LOG" ]
  [ ! -e "$TMPSRC" ]
}

@test "csharp package id: a path separator in the id is rejected" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" "Ondewo/Evil"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid package id"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "csharp package id: dots, digits, underscores and dashes are accepted" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" "Ondewo.Nlu_Client-2"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$OUT/Ondewo.Nlu_Client-2.csproj" ]
  [ -f "$OUT/artifacts/netstandard2.0/Ondewo.Nlu_Client-2.dll" ]
}

@test "csharp package id: \$OndewoPackageId is the fallback when arg 3 is omitted" {
  stage
  export OndewoPackageId=Ondewo.Env.Client
  run bash ./compile-proto-2-csharp.sh protos ""
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$OUT/Ondewo.Env.Client.csproj" ]
  [ -f "$OUT/nupkg/Ondewo.Env.Client.5.14.0.nupkg" ]
}

@test "csharp package id: arg 3 wins over \$OndewoPackageId" {
  stage
  export OndewoPackageId=Ondewo.Env.Client
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Arg.Client
  [ "$status" -eq 0 ]
  [ -f "$OUT/Ondewo.Arg.Client.csproj" ]
  [ ! -e "$OUT/Ondewo.Env.Client.csproj" ]
}

# ---------------------------------------------------------------------------
# the required MSBuild properties
# ---------------------------------------------------------------------------

@test "csharp properties: every required MSBuild property is validated up front" {
  stage
  for prop in OndewoTargetFramework OndewoPackageVersion GoogleProtobufVersion \
              GrpcDotnetVersion GoogleApiCommonProtosVersion
  do
    : > "$PROTOC_MOCK_LOG"
    : > "$DOTNET_MOCK_LOG"
    saved="$(eval "printf '%s' \"\${$prop}\"")"
    unset "$prop"

    run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
    echo "missing property: $prop"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"required build property '$prop' is unset or empty"* ]]
    [ ! -s "$PROTOC_MOCK_LOG" ]
    [ ! -s "$DOTNET_MOCK_LOG" ]

    export "$prop=$saved"
  done
}

@test "csharp properties: an empty (not just unset) property is rejected too" {
  stage
  export OndewoPackageVersion=""
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -ne 0 ]
  [[ "$output" == *"required build property 'OndewoPackageVersion' is unset or empty"* ]]
}

# ---------------------------------------------------------------------------
# project file / readme / nuget.config handling
# ---------------------------------------------------------------------------

@test "csharp manifest: the default project file is copied when the input ships none" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No Ondewo.Test.Client.csproj specified in source directory"* ]]

  run cmp -s "$DEFAULTS/stubs.csproj" "$OUT/Ondewo.Test.Client.csproj"
  [ "$status" -eq 0 ]
}

@test "csharp manifest: a client-supplied .csproj is used verbatim and warned about" {
  printf '<Project Sdk="Microsoft.NET.Sdk"><!-- CLIENT OWNED --></Project>\n' \
    > "$IN/Ondewo.Test.Client.csproj"
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: using the client-supplied Ondewo.Test.Client.csproj"* ]]

  run grep -Fq 'CLIENT OWNED' "$OUT/Ondewo.Test.Client.csproj"
  [ "$status" -eq 0 ]
}

@test "csharp manifest: a .csproj named for a DIFFERENT package id does not count as supplied" {
  printf '<Project Sdk="Microsoft.NET.Sdk"><!-- CLIENT OWNED --></Project>\n' \
    > "$IN/Ondewo.Other.Client.csproj"
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]
  [[ "$output" == *"No Ondewo.Test.Client.csproj specified in source directory"* ]]
  run cmp -s "$DEFAULTS/stubs.csproj" "$OUT/Ondewo.Test.Client.csproj"
  [ "$status" -eq 0 ]
}

@test "csharp readme: the default README.md is staged for packing but never copied out" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]
  run cmp -s "$DEFAULTS/README.md" "$TMPSRC/README.md"
  [ "$status" -eq 0 ]
  [ ! -e "$OUT/README.md" ]
}

@test "csharp readme: a client-supplied README.md is not replaced by the default" {
  printf '# client package readme\n' > "$IN/README.md"
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"No README.md specified in source directory"* ]]
  run grep -Fq 'client package readme' "$TMPSRC/README.md"
  [ "$status" -eq 0 ]
}

@test "csharp nuget.config: the offline feed placeholder is substituted and never leaves the image" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rendering nuget.config pointing at the offline feed '$FEED'"* ]]

  run grep -Fq "$FEED" "$TMPSRC/nuget.config"
  [ "$status" -eq 0 ]
  run grep -Fq '@NUGET_OFFLINE_FEED@' "$TMPSRC/nuget.config"
  [ "$status" -ne 0 ]
  # <clear /> must survive so nuget.org can never be consulted
  run grep -Fq '<clear />' "$TMPSRC/nuget.config"
  [ "$status" -eq 0 ]
  [ ! -e "$OUT/nuget.config" ]
}

@test "csharp nuget.config: a client-supplied one is always overwritten by the rendered offline one" {
  printf '<configuration><packageSources><add key="org" value="https://api.nuget.org/v3/index.json" /></packageSources></configuration>\n' \
    > "$IN/nuget.config"
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]
  run grep -Fq 'api.nuget.org' "$TMPSRC/nuget.config"
  [ "$status" -ne 0 ]
  run grep -Fq "$FEED" "$TMPSRC/nuget.config"
  [ "$status" -eq 0 ]
}

@test "csharp nuget.config: NUGET_OFFLINE_FEED defaults to the container feed path" {
  stage
  unset NUGET_OFFLINE_FEED
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]
  run grep -Fq '/nuget/offline-feed' "$TMPSRC/nuget.config"
  [ "$status" -eq 0 ]
  run grep -Fq -- '--source /nuget/offline-feed' "$DOTNET_MOCK_LOG"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# offline build flags
# ---------------------------------------------------------------------------

@test "csharp offline: restore/build/pack are three calls, all pinned to the offline feed" {
  stage
  run bash ./compile-proto-2-csharp.sh protos "" Ondewo.Test.Client
  [ "$status" -eq 0 ]

  [ "$(log_lines "$DOTNET_MOCK_LOG")" -eq 3 ]
  run grep -Fq -- "dotnet restore $TMPSRC/Ondewo.Test.Client.csproj --source $FEED" "$DOTNET_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "dotnet build $TMPSRC/Ondewo.Test.Client.csproj -c Release --no-restore" "$DOTNET_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "dotnet pack $TMPSRC/Ondewo.Test.Client.csproj -c Release --no-restore --no-build -o $TMPSRC/lib/nupkg" "$DOTNET_MOCK_LOG"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# the sub-scripts, driven directly
# ---------------------------------------------------------------------------

@test "csharp stubs script: missing arguments produce the usage error" {
  subscript_env
  STUBS="$REPO_ROOT/csharp/image-data/compile-proto-2-stubs.sh"
  run bash "$STUBS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-proto-2-stubs.sh"* ]]

  run bash "$STUBS" "$SANDBOX/stubs-out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-proto-2-stubs.sh"* ]]

  run bash "$STUBS" "$SANDBOX/stubs-out" "$IN/protos"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-proto-2-stubs.sh"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "csharp stubs script: compiles the requested sub-tree against the given -I root" {
  subscript_env
  run bash "$REPO_ROOT/csharp/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/stubs-out" "$IN/protos" "$IN/protos/library"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found 2 .proto files"* ]]
  [ -f "$SANDBOX/stubs-out/Ondewo/Mock/Test.cs" ]
  [ -f "$SANDBOX/stubs-out/Ondewo/Mock/TestGrpc.cs" ]
  assert_protoc_arg "-I $IN/protos "
  refute_protoc_arg "$IN/protos/other/other.proto"
}

@test "csharp stubs script: the stubs target directory is emptied before protoc runs" {
  subscript_env
  mkdir -p "$SANDBOX/stubs-out/Ondewo/Old"
  : > "$SANDBOX/stubs-out/Ondewo/Old/Removed.cs"

  run bash "$REPO_ROOT/csharp/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/stubs-out" "$IN/protos" "$IN/protos/library"
  echo "$output"
  [ "$status" -eq 0 ]

  [ ! -e "$SANDBOX/stubs-out/Ondewo/Old/Removed.cs" ]
  [ -f "$SANDBOX/stubs-out/Ondewo/Mock/Test.cs" ]
}

@test "csharp stubs script: a DIRECTORY named *.cs is not counted as a generated stub" {
  # The reported count must be a count of FILES, the same spelling the input-side
  # find uses. Real protoc cannot produce such a directory (a C# namespace
  # segment carries no dot), so the pathological tree is produced by a stand-in
  # protoc rather than by a fixture the script could special-case.
  subscript_env
  shadow_protoc <<'MOCK'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    --csharp_out=*)
      dir="${a#*=}"; dir="${dir##*:}"
      mkdir -p "$dir/Ondewo/Mock" "$dir/Ondewo/Legacy.cs"
      : > "$dir/Ondewo/Mock/Test.cs"
      ;;
  esac
done
MOCK

  run bash "$REPO_ROOT/csharp/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/stubs-out" "$IN/protos" "$IN/protos/library"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/stubs-out/Ondewo/Legacy.cs" ]
  [[ "$output" == *"files generated by proto compilation: 1"* ]]
}

@test "csharp lib script: missing arguments produce the usage error" {
  subscript_env
  LIB="$REPO_ROOT/csharp/image-data/compile-stubs-2-lib.sh"
  run bash "$LIB"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-stubs-2-lib.sh"* ]]

  run bash "$LIB" "$SANDBOX/nowhere"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-stubs-2-lib.sh"* ]]
  [ ! -s "$DOTNET_MOCK_LOG" ]
}

@test "csharp lib script: a missing compile directory fails loudly" {
  subscript_env
  run bash "$REPO_ROOT/csharp/image-data/compile-stubs-2-lib.sh" \
    "$SANDBOX/nowhere" Ondewo.Test.Client
  [ "$status" -ne 0 ]
  [[ "$output" == *"compile directory"*"does not exist"* ]]
  [ ! -s "$DOTNET_MOCK_LOG" ]
}

@test "csharp lib script: a missing project file fails loudly and names the template" {
  subscript_env
  SRC="$SANDBOX/lib-src"; mkdir -p "$SRC/api"
  run bash "$REPO_ROOT/csharp/image-data/compile-stubs-2-lib.sh" "$SRC" Ondewo.Test.Client
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no project file"* ]]
  [[ "$output" == *"default-lib-files/stubs.csproj"* ]]
  [ ! -s "$DOTNET_MOCK_LOG" ]
}

@test "csharp lib script: a missing api/ directory fails loudly before dotnet runs" {
  subscript_env
  SRC="$SANDBOX/lib-src"; mkdir -p "$SRC"
  cp "$DEFAULTS/stubs.csproj" "$SRC/Ondewo.Test.Client.csproj"
  run bash "$REPO_ROOT/csharp/image-data/compile-stubs-2-lib.sh" "$SRC" Ondewo.Test.Client
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no generated stubs directory"* ]]
  [ ! -s "$DOTNET_MOCK_LOG" ]
}

@test "csharp lib script: lib/ is emptied before the restore so nothing is compiled twice" {
  subscript_env
  SRC="$SANDBOX/lib-src"
  mkdir -p "$SRC/api/Ondewo/Mock" "$SRC/lib/api/Ondewo/Mock"
  cp "$DEFAULTS/stubs.csproj" "$SRC/Ondewo.Test.Client.csproj"
  : > "$SRC/api/Ondewo/Mock/Test.cs"
  : > "$SRC/lib/api/Ondewo/Mock/StaleFromPreviousRun.cs"
  : > "$SRC/lib/leftover.txt"

  run bash "$REPO_ROOT/csharp/image-data/compile-stubs-2-lib.sh" "$SRC" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 0 ]

  [ ! -e "$SRC/lib/leftover.txt" ]
  [ ! -e "$SRC/lib/api/Ondewo/Mock/StaleFromPreviousRun.cs" ]
  [ -f "$SRC/lib/api/Ondewo/Mock/Test.cs" ]
  [ -f "$SRC/lib/Ondewo.Test.Client.csproj" ]
  [ -f "$SRC/lib/artifacts/netstandard2.0/Ondewo.Test.Client.dll" ]
  [ -f "$SRC/lib/nupkg/Ondewo.Test.Client.5.14.0.nupkg" ]
  # bin/ and obj/ stay in the compile directory
  [ -d "$SRC/bin/Release" ]
  [ ! -e "$SRC/lib/bin" ]
  [ ! -e "$SRC/lib/obj" ]
}

@test "csharp lib script: a build that writes no bin/Release aborts before anything is collected" {
  subscript_env
  # restore/build/pack all succeed, but the assemblies go to artifacts/bin/... -
  # the collection step has nothing to read and must say so instead of shipping
  # a lib/ with stubs and a .csproj but no assembly.
  shadow_dotnet_artifacts_layout
  SRC="$SANDBOX/lib-src"
  mkdir -p "$SRC/api/Ondewo/Mock"
  cp "$DEFAULTS/stubs.csproj" "$SRC/Ondewo.Test.Client.csproj"
  : > "$SRC/api/Ondewo/Mock/Test.cs"

  run bash "$REPO_ROOT/csharp/image-data/compile-stubs-2-lib.sh" "$SRC" Ondewo.Test.Client
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: dotnet build produced no '$SRC/bin/Release' output directory - exiting"* ]]
  # it aborts at the collection step, i.e. only after all three dotnet calls ran
  [ "$(log_lines "$DOTNET_MOCK_LOG")" -eq 3 ]
  [ ! -e "$SRC/bin" ]
  [ -f "$SRC/artifacts/bin/Ondewo.Test.Client/release/Ondewo.Test.Client.dll" ]
  # lib/ was created empty by the pre-build wipe and holds only what dotnet pack
  # itself wrote there - no api/, no artifacts/, no project file, and the
  # closing banner never printed
  [ -d "$SRC/lib" ]
  [ ! -e "$SRC/lib/api" ]
  [ ! -e "$SRC/lib/artifacts" ]
  [ ! -e "$SRC/lib/Ondewo.Test.Client.csproj" ]
  [[ "$output" != *"Finished csharp build."* ]]
}

@test "csharp lib script: the missing-bin/Release abort goes to stderr" {
  subscript_env
  shadow_dotnet_artifacts_layout
  SRC="$SANDBOX/lib-src"
  mkdir -p "$SRC/api"
  cp "$DEFAULTS/stubs.csproj" "$SRC/Ondewo.Test.Client.csproj"

  run bash -c "bash '$REPO_ROOT/csharp/image-data/compile-stubs-2-lib.sh' '$SRC' Ondewo.Test.Client 2>&1 >/dev/null"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"produced no"*"bin/Release"*"output directory"* ]]
}

# ---------------------------------------------------------------------------
# build.sh / example / Makefile wiring (docker is PATH-mocked; nothing is built)
# ---------------------------------------------------------------------------

@test "csharp build.sh: builds the ondewo-csharp-proto-compiler:latest tag from its own dir" {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  run sh "$REPO_ROOT/csharp/build.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  run grep -Fq -- "docker build --no-cache -t ondewo-csharp-proto-compiler:latest $REPO_ROOT/csharp" \
    "$SANDBOX/docker.log"
  [ "$status" -eq 0 ]
}

@test "csharp build.sh: a failing docker build propagates instead of printing the success banner" {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  FAIL_BUILD_MATCH="ondewo-csharp-proto-compiler" run sh "$REPO_ROOT/csharp/build.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"✅"* ]]
}

@test "csharp example: run-compile.sh mounts both volumes and passes an EMPTY target subdir" {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  cp "$REPO_ROOT/csharp/example/run-compile.sh" "$SANDBOX/run.sh"
  run sh "$SANDBOX/run.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/lib" ]

  run grep -Fq -- "-v $SANDBOX:/input-volume -v $SANDBOX/lib:/output-volume" "$SANDBOX/docker.log"
  [ "$status" -eq 0 ]
  # the quoted empty $2 survives as an empty field (two spaces), so the package
  # id cannot shift into the target-subdir slot
  run grep -Fq -- "ondewo-csharp-proto-compiler protos  Ondewo.Example.Client" "$SANDBOX/docker.log"
  [ "$status" -eq 0 ]
  # no -it on the codegen invocation - it breaks every non-interactive caller
  run grep -Fq -- "docker run -it" "$SANDBOX/docker.log"
  [ "$status" -ne 0 ]
}

@test "csharp Makefile: build tags the same image as build.sh" {
  run bash -c "cd '$REPO_ROOT/csharp' && make -n build | grep -v '^[[:space:]]*#'"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker build -t ondewo-csharp-proto-compiler ."* ]]
}

@test "csharp Makefile: run builds \${shell pwd} mounts and quoted args, without -it or --user" {
  # `make -n` only prints the recipe, so nothing is created in the repo tree;
  # the leading comment lines (which mention "-it" in prose) are filtered out.
  run bash -c "cd '$REPO_ROOT/csharp' && make -n run | grep -v '^[[:space:]]*#'"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-v $REPO_ROOT/csharp/protos:/input-volume/protos"* ]]
  [[ "$output" == *"-v $REPO_ROOT/csharp/lib:/output-volume"* ]]
  [[ "$output" == *'ondewo-csharp-proto-compiler "protos" "" "Ondewo.Grpc.Client"'* ]]
  [[ "$output" != *"-it"* ]]
  [[ "$output" != *"--user"* ]]
}

@test "csharp Makefile: PROTO_DIR/TARGET_DIR/OUTPUT_DIR/PACKAGE_ID overrides reach the container" {
  run bash -c "cd '$REPO_ROOT/csharp' && make -n run PROTO_DIR=api/ondewo-nlu-api TARGET_DIR=ondewo OUTPUT_DIR=out PACKAGE_ID=Ondewo.Nlu.Client | grep -v '^[[:space:]]*#'"
  echo "$output"
  [ "$status" -eq 0 ]
  # the proto dir is mounted under its BASENAME, which is also argument 1
  [[ "$output" == *"-v $REPO_ROOT/csharp/api/ondewo-nlu-api:/input-volume/ondewo-nlu-api"* ]]
  [[ "$output" == *"-v $REPO_ROOT/csharp/out:/output-volume"* ]]
  [[ "$output" == *'ondewo-csharp-proto-compiler "ondewo-nlu-api" "ondewo" "Ondewo.Nlu.Client"'* ]]
}
