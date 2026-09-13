#!/usr/bin/env bats
# End-to-end + unit coverage for the cpp proto-compiler target, driven on the
# HOST: the container paths (/image-data, /input-volume, /output-volume, the
# CMake build/install trees) are overridden through the env knobs the scripts
# expose, and the toolchain (protoc, grpc_cpp_plugin, cmake) is PATH-mocked, so
# the whole pipeline
#
#   compile-proto-2-cpp.sh
#     -> compile-proto-2-stubs.sh  (protoc + the transitive-import resolver)
#     -> make-lib-entry-point.sh   (the public-api.h umbrella header)
#     -> compile-stubs-2-lib.sh    (cmake configure / --build / --install)
#     -> copy-back to the output volume
#
# runs without Docker, network or a real C++ toolchain. Every case asserts on
# BEHAVIOUR: which binary was called with which arguments (mock argv logs),
# which files landed where, and that failures propagate with a non-zero status.

load 'helpers/setup'

setup() {
  common_setup
  # the extra-include knob is read as "unset vs set" (unset = auto-detect), and it
  # matches none of scrub_toolchain_env's prefixes, so an ambient value in the
  # developer's shell would silently steer every case in this file
  unset EXTRA_PROTO_DIRS
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  export CMAKE_MOCK_LOG="$SANDBOX/cmake.log"
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"

  IN="$SANDBOX/input"
  OUT="$SANDBOX/output"
  mkdir -p "$IN/protos/library" "$IN/protos/dependency" "$IN/protos/google/api" \
           "$IN/protos/other" "$OUT"

  # test.proto -> dependency/myimport.proto -> google/api/annotations.proto is a
  # three-level import closure; google/protobuf/timestamp.proto is the excluded
  # well-known type (deliberately NOT present on disk - the resolver must skip it
  # rather than fail to resolve it).
  cat > "$IN/protos/library/test.proto" <<'PROTO'
syntax = "proto3";
package library;
import "dependency/myimport.proto";
import "google/protobuf/timestamp.proto";
message Test { string name = 1; }
service SimpleService { rpc SendTest (Test) returns (Test); }
PROTO
  cat > "$IN/protos/dependency/myimport.proto" <<'PROTO'
syntax = "proto3";
package dependency;
import "google/api/annotations.proto";
message MyImport { string name = 1; }
PROTO
  printf 'syntax = "proto3";\npackage google.api;\nmessage Http { string x = 1; }\n' \
    > "$IN/protos/google/api/annotations.proto"
  # not imported by anything -> only compiled when the whole root is the target
  printf 'syntax = "proto3";\npackage other;\nmessage Unused { string x = 1; }\n' \
    > "$IN/protos/other/unused.proto"
}

teardown() { common_teardown; }

# Copy the cpp image-data tree into the sandbox (nothing is ever written into the
# repo tree), cd there (the orchestrator invokes its siblings as ./x.sh) and point
# every container path at the sandbox. The knobs are exported AFTER common_setup
# on purpose: scrub_toolchain_env() wipes exactly these namespaces first.
stage() {
  cp -r "$REPO_ROOT/cpp/image-data" "$SANDBOX/image-data"
  cd "$SANDBOX/image-data"
  TEMP="$SANDBOX/temp-src"
  BUILD="$SANDBOX/cmake-build"
  INSTALL="$SANDBOX/cmake-install"
  export IMAGE_DATA_DIRECTORY="$SANDBOX/image-data"
  export INPUT_VOLUME_FS="$IN"
  export OUTPUT_VOLUME_FS="$OUT"
  export TEMP_SRC_DIRECTORY="$TEMP"
  export BUILD_DIRECTORY="$BUILD"
  export INSTALL_DIRECTORY="$INSTALL"
  # the scripts only `command -v` this one; protoc (mocked) would exec it
  export GRPC_CPP_PLUGIN=grpc_cpp_plugin
  export ONDEWO_CLIENT_VERSION=5.14.0
  # keep the build deterministic instead of host-core-count dependent
  export CMAKE_BUILD_PARALLEL_LEVEL=2
}

# checksum every file of a tree, so "the input volume is never mutated" is a
# content assertion, not just a file-list one (cksum is POSIX; BSD and GNU agree)
tree_checksums() {
  find "$1" -type f -exec cksum {} + | sort
}

# Put a cmake on PATH whose `--install` step EXITS 0 but installs nothing - the
# shape of a CMakeLists whose install() rules matched no file. Configure and
# --build are delegated to the suite's mock cmake (and still logged), so
# compile-stubs-2-lib.sh reports success and the orchestrator reaches its own
# copy-back guards with exactly the state it is there to catch.
#   $1 = none  -> the install prefix is never created  (install tree missing)
#   $1 = empty -> the install prefix is created, empty (nothing installed)
stub_silent_install_cmake() {
  mkdir -p "$SANDBOX/silent-install-bin"
  cat > "$SANDBOX/silent-install-bin/cmake" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "--install" ]; then
  printf 'cmake %s\n' "$*" >> "${CMAKE_MOCK_LOG:-/dev/null}"
  if [ "${SILENT_INSTALL_MODE:-none}" = "empty" ]; then
    # real cmake reads the prefix out of the configured cache; so does this stub
    prefix=$(sed -n 's|^CMAKE_INSTALL_PREFIX:[^=]*=\(.*\)$|\1|p' "$2/CMakeCache.txt" | head -1)
    mkdir -p "$prefix"
  fi
  echo "-- Install configuration: mock -> nothing installed"
  exit 0
fi
exec "$REAL_CMAKE" "$@"
SH
  chmod +x "$SANDBOX/silent-install-bin/cmake"
  export REAL_CMAKE="$MOCK_BIN/cmake" SILENT_INSTALL_MODE="$1"
  PATH="$SANDBOX/silent-install-bin:$PATH"
  export PATH
}

protoc_args() { cat "$PROTOC_MOCK_LOG"; }

# ---------------------------------------------------------------- happy path

@test "cpp e2e: full pipeline writes the documented layout to the output volume" {
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]

  # generated stub sources
  [ -f "$OUT/api/mock.pb.h" ]
  [ -f "$OUT/api/mock.pb.cc" ]
  [ -f "$OUT/api/mock.grpc.pb.h" ]
  [ -f "$OUT/api/mock.grpc.pb.cc" ]
  # umbrella header + the two build files (output volume had neither)
  [ -f "$OUT/public-api.h" ]
  [ -f "$OUT/CMakeLists.txt" ]
  [ -f "$OUT/ondewo-client-config.cmake.in" ]
  # the CMake install tree
  [ -f "$OUT/include/mylib/public-api.h" ]
  [ -f "$OUT/include/mylib/mock.pb.h" ]
  [ -f "$OUT/include/mylib/mock.grpc.pb.h" ]
  [ -f "$OUT/lib/libmylib.a" ]
  [ -f "$OUT/lib/cmake/mylib/mylib-config.cmake" ]
  [ -f "$OUT/lib/cmake/mylib/mylib-config-version.cmake" ]
  [ -f "$OUT/lib/cmake/mylib/mylib-targets.cmake" ]
  [ -f "$OUT/lib/cmake/mylib/mylib-targets-release.cmake" ]
  [[ "$output" == *"C++: .proto to cpp library compilation finished successfully"* ]]
}

@test "cpp e2e: the mounted input volume is never mutated" {
  stage
  before="$(tree_checksums "$IN")"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  after="$(tree_checksums "$IN")"
  [ "$before" = "$after" ]
  # nothing new created in it either
  [ ! -d "$IN/api" ]
  [ ! -d "$IN/lib" ]
  [ ! -f "$IN/public-api.h" ]
  [ ! -f "$IN/CMakeLists.txt" ]
}

@test "cpp e2e: compilation happens in the temp copy, not in the input volume" {
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  # the whole input volume is copied there ...
  [ -f "$TEMP/protos/library/test.proto" ]
  [ -f "$TEMP/protos/dependency/myimport.proto" ]
  # ... and everything generated lands beside the copy, never in $IN
  [ -f "$TEMP/api/mock.pb.cc" ]
  [ -f "$TEMP/public-api.h" ]
  [ -f "$TEMP/CMakeLists.txt" ]
  # protoc was pointed at the copy, not at the mounted volume
  grep -Fq -- "-I $TEMP/protos " "$PROTOC_MOCK_LOG"
  run grep -Fq -- "-I $IN/protos" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "cpp e2e: build and install trees live outside the copied source tree" {
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  # a CMAKE_INSTALL_PREFIX inside $TEMP would copy the client's own files back out
  [ -f "$BUILD/CMakeCache.txt" ]
  [ -d "$INSTALL/include/mylib" ]
  [ ! -d "$TEMP/build" ]
  [ ! -d "$TEMP/install" ]
  grep -Fq -- "-B $BUILD " "$CMAKE_MOCK_LOG"
  grep -Fq -- "-DCMAKE_INSTALL_PREFIX=$INSTALL " "$CMAKE_MOCK_LOG"
}

@test "cpp e2e: unset path knobs default to the /image-data-rooted container paths" {
  stage
  unset TEMP_SRC_DIRECTORY BUILD_DIRECTORY INSTALL_DIRECTORY
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  [ -f "$IMAGE_DATA_DIRECTORY/src/api/mock.pb.cc" ]
  [ -f "$IMAGE_DATA_DIRECTORY/build/CMakeCache.txt" ]
  [ -f "$IMAGE_DATA_DIRECTORY/install/lib/libmylib.a" ]
}

# ------------------------------------------------------------ argument handling

@test "cpp args: with no arguments the protos dir defaults to 'protos' and the library to ondewo_grpc_client" {
  stage
  run bash ./compile-proto-2-cpp.sh
  [ "$status" -eq 0 ]
  grep -Fq -- "-I $TEMP/protos " "$PROTOC_MOCK_LOG"
  grep -Fq -- "-DONDEWO_LIBRARY_NAME=ondewo_grpc_client " "$CMAKE_MOCK_LOG"
  [ -f "$OUT/lib/libondewo_grpc_client.a" ]
  [ -d "$OUT/include/ondewo_grpc_client" ]
  [ -d "$OUT/lib/cmake/ondewo_grpc_client" ]
}

@test "cpp args: an explicit relative protos dir is resolved inside the input volume" {
  mkdir -p "$IN/vendor/apis/pkg"
  printf 'syntax = "proto3";\npackage pkg;\nmessage A { string x = 1; }\n' \
    > "$IN/vendor/apis/pkg/a.proto"
  stage
  run bash ./compile-proto-2-cpp.sh vendor/apis "" mylib
  [ "$status" -eq 0 ]
  grep -Fq -- "-I $TEMP/vendor/apis " "$PROTOC_MOCK_LOG"
  grep -Fq -- " pkg/a.proto" "$PROTOC_MOCK_LOG"
  # the protos/ tree is NOT the root for this run
  run grep -Fq -- "library/test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "cpp args: the target subdir scopes compilation to that sub-tree (imports still resolved)" {
  stage
  run bash ./compile-proto-2-cpp.sh protos library mylib
  [ "$status" -eq 0 ]
  # entry proto + its transitive imports, root-relative
  grep -Fq -- " library/test.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- " dependency/myimport.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- " google/api/annotations.proto" "$PROTOC_MOCK_LOG"
  # a sibling sub-tree nobody imports must not be dragged in
  run grep -Fq -- "other/unused.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # the include root stays the protos ROOT, not the selected sub-dir
  grep -Fq -- "-I $TEMP/protos " "$PROTOC_MOCK_LOG"
}

@test "cpp args: without a target subdir the whole protos root is compiled" {
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  grep -Fq -- " library/test.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- " other/unused.proto" "$PROTOC_MOCK_LOG"
}

@test "cpp args: '.' as the target subdir means the whole root (the example/Makefile spelling)" {
  stage
  run bash ./compile-proto-2-cpp.sh protos . mylib
  [ "$status" -eq 0 ]
  grep -Fq -- " library/test.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- " other/unused.proto" "$PROTOC_MOCK_LOG"
  [ -f "$OUT/lib/libmylib.a" ]
}

@test "cpp args: an invalid library name is rejected before anything is generated" {
  stage
  run bash ./compile-proto-2-cpp.sh protos "" "bad name!"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a valid CMake target name"* ]]
  # the guard fires before the input copy / protoc / cmake
  [ ! -e "$PROTOC_MOCK_LOG" ]
  [ ! -e "$CMAKE_MOCK_LOG" ]
  [ ! -d "$TEMP" ]
}

# ------------------------------------------------------------- protoc contract

@test "cpp protoc: one invocation with the cpp + grpc out flags, the plugin and the -I root" {
  stage
  run bash ./compile-proto-2-cpp.sh protos library mylib
  [ "$status" -eq 0 ]
  invocations=$(grep -c '^protoc ' "$PROTOC_MOCK_LOG")
  [ "$invocations" -eq 1 ]
  grep -Fq -- "--cpp_out=$TEMP/api " "$PROTOC_MOCK_LOG"
  grep -Fq -- "--grpc_out=$TEMP/api " "$PROTOC_MOCK_LOG"
  grep -Fq -- "--plugin=protoc-gen-grpc=grpc_cpp_plugin " "$PROTOC_MOCK_LOG"
  grep -Fq -- "-I $TEMP/protos " "$PROTOC_MOCK_LOG"
  # proto paths are passed root-relative (that is what mirrors the package path
  # into api/ and matches the #include lines protoc writes into the stubs)
  run grep -Fq -- " $TEMP/protos/library/test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "cpp protoc: the google/protobuf well-known types are never compiled" {
  stage
  run bash ./compile-proto-2-cpp.sh protos library mylib
  [ "$status" -eq 0 ]
  # test.proto imports google/protobuf/timestamp.proto, which does not exist under
  # the proto root: the resolver must EXCLUDE it (not fail to resolve it), because
  # the well-known types are already inside libprotobuf - regenerating them
  # duplicates symbols and breaks the link
  run grep -Fq "google/protobuf" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # ... while a non-well-known google import IS resolved and compiled
  grep -Fq -- " google/api/annotations.proto" "$PROTOC_MOCK_LOG"
}

@test "cpp protoc: a google/protobuf proto vendored inside the compiled tree is not fed to protoc" {
  mkdir -p "$IN/protos/google/protobuf"
  printf 'syntax = "proto3";\npackage google.protobuf;\nmessage Timestamp { int64 s = 1; }\n' \
    > "$IN/protos/google/protobuf/timestamp.proto"
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  run grep -Fq "google/protobuf/timestamp.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "cpp protoc: an import resolved beside the importing proto is compiled too" {
  # a three-link chain whose MIDDLE link is not root-relative: myimport.proto (an
  # import, not an entry) imports "sibling_helper.proto", which exists only beside
  # it - <root>/sibling_helper.proto does not. The resolver falls back to the
  # importing file's own directory, and the closure then continues from there
  # (sibling_helper.proto -> google/api/annotations.proto). Missing that fallback
  # would abort the run as "Failed to resolve dependency", so this is the whole
  # difference between a buildable library and no library at all.
  cat > "$IN/protos/dependency/myimport.proto" <<'PROTO'
syntax = "proto3";
package dependency;
import "sibling_helper.proto";
message MyImport { string name = 1; }
PROTO
  cat > "$IN/protos/dependency/sibling_helper.proto" <<'PROTO'
syntax = "proto3";
package dependency;
import "google/api/annotations.proto";
message SiblingHelper { string name = 1; }
PROTO
  stage
  run bash ./compile-proto-2-cpp.sh protos library mylib
  [ "$status" -eq 0 ]
  # the entry proto, the root-relative import, the sibling-resolved import and
  # the import that one pulls in transitively all reach protoc ...
  grep -Fq -- " library/test.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- " dependency/myimport.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- " dependency/sibling_helper.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- " google/api/annotations.proto" "$PROTOC_MOCK_LOG"
  # ... spelled relative to the PROTO ROOT (protoc rejects any other spelling),
  # never as the bare name the import line used
  run grep -Eq -- ' sibling_helper\.proto' "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # ... and the closure is still a closure: nothing nobody imports is dragged in
  run grep -Fq -- "other/unused.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "cpp protoc: an unresolvable import aborts the run" {
  printf 'syntax = "proto3";\npackage library;\nimport "nowhere/missing.proto";\nmessage T {}\n' \
    > "$IN/protos/library/test.proto"
  stage
  run bash ./compile-proto-2-cpp.sh protos library mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to resolve dependency"* ]]
  [[ "$output" == *"dependency resolution failed"* ]]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]
  [ ! -e "$CMAKE_MOCK_LOG" ]
}

# -------------------------------------------------- extra protoc include dirs
# ondewo-survey-api does not lay its google imports out the way nlu/csi/vtsi do:
# they live under <protos_root>/googleapis/google/... instead of
# <protos_root>/google/..., so `import "google/api/annotations.proto";` resolves
# against neither the proto root nor the importing file's own directory and the
# whole run used to abort. EXTRA_PROTO_DIRS adds include roots; unset, it
# auto-detects exactly that layout.

# A survey-shaped tree: googleapis/ carries the google imports, the proto root
# has no google/ of its own, and the extra root has an internal import of its own
# (annotations -> http) so the closure has to keep resolving once it is inside it.
stage_googleapis_layout() {
  rm -rf "${IN:?}/protos"
  mkdir -p "$IN/protos/ondewo/survey" "$IN/protos/googleapis/google/api"
  cat > "$IN/protos/ondewo/survey/survey.proto" <<'PROTO'
syntax = "proto3";
package ondewo.survey;
import "google/api/annotations.proto";
import "google/protobuf/empty.proto";
message Survey { string name = 1; }
service Surveys { rpc GetSurvey (Survey) returns (Survey); }
PROTO
  printf 'syntax = "proto3";\npackage google.api;\nimport "google/api/http.proto";\nmessage Annotations { string x = 1; }\n' \
    > "$IN/protos/googleapis/google/api/annotations.proto"
  printf 'syntax = "proto3";\npackage google.api;\nmessage HttpRule { string x = 1; }\n' \
    > "$IN/protos/googleapis/google/api/http.proto"
}

# how many "-I " flags reached protoc (BSD wc pads, so count with grep -c)
include_flag_count() { grep -o -- ' -I ' "$PROTOC_MOCK_LOG" | grep -c . || true; }

@test "cpp extra includes: a vendored googleapis/ is auto-detected and added as a second -I" {
  stage_googleapis_layout
  stage
  run bash ./compile-proto-2-cpp.sh protos ondewo mylib
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected a vendored 'googleapis/' and no 'google/' at the protos root"* ]]
  # the proto root stays first, the extra root is appended after it
  grep -Fq -- "-I $TEMP/protos -I $TEMP/protos/googleapis " "$PROTOC_MOCK_LOG"
  [ "$(include_flag_count)" -eq 2 ]
  # the closure crossed into the extra root and kept resolving inside it
  grep -Fq -- " ondewo/survey/survey.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- " google/api/annotations.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- " google/api/http.proto" "$PROTOC_MOCK_LOG"
  # and the library was built from what that produced
  [ -f "$OUT/lib/libmylib.a" ]
  [ -f "$OUT/api/mock.pb.cc" ]
}

@test "cpp extra includes: protos under the extra root are spelled relative to THAT root" {
  # the subtle half: protoc resolves the import line against -I <root>/googleapis,
  # so the file list must say google/api/annotations.proto. Spelled relative to the
  # proto root instead (googleapis/google/api/annotations.proto) protoc sees one
  # file under two names and aborts with "was previously imported under a different
  # name" - a failure this suite would otherwise only meet inside the image.
  stage_googleapis_layout
  stage
  run bash ./compile-proto-2-cpp.sh protos ondewo mylib
  [ "$status" -eq 0 ]
  run grep -Fq -- " googleapis/google/api/" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "cpp extra includes: the well-known types stay excluded in the googleapis layout" {
  # survey.proto imports google/protobuf/empty.proto and the vendored googleapis
  # tree HAS a copy of it: the extra include dir must not turn the well-known types
  # into compiled sources (they are already inside libprotobuf -> duplicate symbols)
  stage_googleapis_layout
  mkdir -p "$IN/protos/googleapis/google/protobuf"
  printf 'syntax = "proto3";\npackage google.protobuf;\nmessage Empty {}\n' \
    > "$IN/protos/googleapis/google/protobuf/empty.proto"
  stage
  run bash ./compile-proto-2-cpp.sh protos ondewo mylib
  [ "$status" -eq 0 ]
  run grep -Fq "google/protobuf" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "cpp extra includes: nothing is added for a proto root that carries its own google/" {
  # the 36 product/language combinations that already worked: one -I, no detection
  stage
  run bash ./compile-proto-2-cpp.sh protos library mylib
  [ "$status" -eq 0 ]
  [[ "$output" != *"Detected a vendored"* ]]
  [ "$(include_flag_count)" -eq 1 ]
  grep -Fq -- "-I $TEMP/protos " "$PROTOC_MOCK_LOG"
  grep -Fq -- " google/api/annotations.proto" "$PROTOC_MOCK_LOG"
}

@test "cpp extra includes: a googleapis/ beside an existing google/ is NOT added" {
  # both layouts at once: google/ already resolves every import, so adding the
  # vendored tree could only introduce a second spelling of the same file
  mkdir -p "$IN/protos/googleapis/google/api"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Annotations { string x = 1; }\n' \
    > "$IN/protos/googleapis/google/api/annotations.proto"
  stage
  run bash ./compile-proto-2-cpp.sh protos library mylib
  [ "$status" -eq 0 ]
  [[ "$output" != *"Detected a vendored"* ]]
  [ "$(include_flag_count)" -eq 1 ]
  run grep -Fq -- "-I $TEMP/protos/googleapis" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "cpp extra includes: EXTRA_PROTO_DIRS overrides the auto-detection" {
  # a tree whose extra root is named something else entirely - only the env knob
  # can find it
  rm -rf "${IN:?}/protos"
  mkdir -p "$IN/protos/ondewo/survey" "$IN/protos/vendor/google/api"
  printf 'syntax = "proto3";\npackage ondewo.survey;\nimport "google/api/annotations.proto";\nmessage S { string x = 1; }\n' \
    > "$IN/protos/ondewo/survey/survey.proto"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Annotations { string x = 1; }\n' \
    > "$IN/protos/vendor/google/api/annotations.proto"
  stage
  export EXTRA_PROTO_DIRS="vendor"
  run bash ./compile-proto-2-cpp.sh protos ondewo mylib
  [ "$status" -eq 0 ]
  [[ "$output" == *"Extra proto include dirs (EXTRA_PROTO_DIRS): 'vendor'"* ]]
  grep -Fq -- "-I $TEMP/protos -I $TEMP/protos/vendor " "$PROTOC_MOCK_LOG"
  grep -Fq -- " google/api/annotations.proto" "$PROTOC_MOCK_LOG"
  [ -f "$OUT/lib/libmylib.a" ]
}

@test "cpp extra includes: EXTRA_PROTO_DIRS takes a list, in order" {
  rm -rf "${IN:?}/protos"
  mkdir -p "$IN/protos/ondewo" "$IN/protos/first/google/api" "$IN/protos/second/extra"
  printf 'syntax = "proto3";\npackage ondewo;\nimport "google/api/annotations.proto";\nimport "extra/more.proto";\nmessage S { string x = 1; }\n' \
    > "$IN/protos/ondewo/survey.proto"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Annotations { string x = 1; }\n' \
    > "$IN/protos/first/google/api/annotations.proto"
  printf 'syntax = "proto3";\npackage extra;\nmessage More { string x = 1; }\n' \
    > "$IN/protos/second/extra/more.proto"
  stage
  export EXTRA_PROTO_DIRS="first second"
  run bash ./compile-proto-2-cpp.sh protos ondewo mylib
  [ "$status" -eq 0 ]
  grep -Fq -- "-I $TEMP/protos -I $TEMP/protos/first -I $TEMP/protos/second " "$PROTOC_MOCK_LOG"
  [ "$(include_flag_count)" -eq 3 ]
  # each import spelled relative to the extra root that resolves it
  grep -Fq -- " google/api/annotations.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- " extra/more.proto" "$PROTOC_MOCK_LOG"
}

@test "cpp extra includes: an empty EXTRA_PROTO_DIRS disables the auto-detection" {
  stage_googleapis_layout
  stage
  export EXTRA_PROTO_DIRS=""
  run bash ./compile-proto-2-cpp.sh protos ondewo mylib
  [ "$status" -ne 0 ]
  [[ "$output" != *"Detected a vendored"* ]]
  [[ "$output" == *"Failed to resolve dependency"* ]]
  [[ "$output" == *"dependency resolution failed"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "cpp extra includes: an EXTRA_PROTO_DIRS entry that does not exist is rejected up front" {
  stage_googleapis_layout
  stage
  export EXTRA_PROTO_DIRS="googleapis nope"
  run bash ./compile-proto-2-cpp.sh protos ondewo mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"the extra proto include directory '$TEMP/protos/nope' does not exist"* ]]
  [[ "$output" == *"relative to the protos root"* ]]
  # the guard fires before the resolver and before protoc
  [ ! -e "$PROTOC_MOCK_LOG" ]
  [ ! -e "$CMAKE_MOCK_LOG" ]
}

@test "cpp extra includes: an import that resolves under neither root still aborts" {
  # the extra include dir widens the search, it does not silence the failure
  stage_googleapis_layout
  printf 'syntax = "proto3";\npackage ondewo.survey;\nimport "google/api/nowhere.proto";\nmessage S {}\n' \
    > "$IN/protos/ondewo/survey/survey.proto"
  stage
  run bash ./compile-proto-2-cpp.sh protos ondewo mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to resolve dependency"* ]]
  # ... and the message names the extra roots that were searched too
  [[ "$output" == *"extra include roots: $TEMP/protos/googleapis"* ]]
  [[ "$output" == *"or the extra include dirs: $TEMP/protos/googleapis"* ]]
}

# -------------------------------------------------------------- cmake contract

@test "cpp cmake: configure, build and install run exactly once each with the injected -D values" {
  stage
  export ONDEWO_CLIENT_VERSION=7.8.9
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  calls=$(grep -c '^cmake ' "$CMAKE_MOCK_LOG")
  [ "$calls" -eq 3 ]
  # 1) configure: source tree, fresh build tree, install prefix, name + version
  grep -Fq -- "-S $TEMP -B $BUILD " "$CMAKE_MOCK_LOG"
  grep -Fq -- "-DCMAKE_BUILD_TYPE=Release " "$CMAKE_MOCK_LOG"
  grep -Fq -- "-DONDEWO_LIBRARY_NAME=mylib " "$CMAKE_MOCK_LOG"
  grep -Fq -- "-DONDEWO_LIBRARY_VERSION=7.8.9" "$CMAKE_MOCK_LOG"
  # 2) build, with the parallelism escape hatch honoured
  grep -Fq -- "--build $BUILD --parallel 2" "$CMAKE_MOCK_LOG"
  # 3) install (the prefix comes from the cache, so it takes only the build dir)
  grep -Fxq "cmake --install $BUILD" "$CMAKE_MOCK_LOG"
  # the version reaches the installed CMake package
  grep -Fq "7.8.9" "$OUT/lib/cmake/mylib/mylib-config-version.cmake"
}

@test "cpp cmake: without the escape hatch the parallel level is a positive number" {
  # the default comes from getconf (NOT nproc, which macOS lacks) with a literal
  # fallback, so assert the shape rather than a host-dependent value
  stage
  unset CMAKE_BUILD_PARALLEL_LEVEL
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  jobs_used=$(sed -n 's|.*--parallel \([0-9][0-9]*\).*|\1|p' "$CMAKE_MOCK_LOG")
  [ -n "$jobs_used" ]
  [ "$jobs_used" -ge 1 ]
}

@test "cpp cmake: a non-numeric library version is rejected before cmake is called" {
  stage
  export ONDEWO_CLIENT_VERSION=5.15.0-rc1
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a dotted numeric version"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
  [ ! -e "$CMAKE_MOCK_LOG" ]
  [ ! -d "$OUT/api" ]
}

@test "cpp cmake: stale build and install trees from a previous run are wiped first" {
  stage
  mkdir -p "$BUILD" "$INSTALL/lib"
  printf 'stale cache\n' > "$BUILD/stale-cache.txt"
  printf 'stale archive\n' > "$INSTALL/lib/libghost.a"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  [ ! -f "$BUILD/stale-cache.txt" ]
  [ ! -f "$INSTALL/lib/libghost.a" ]
  # and therefore the stale artifact never reaches the output volume
  [ ! -f "$OUT/lib/libghost.a" ]
}

# ------------------------------------------------------- output volume handling

@test "cpp output: a missing output volume falls back to <input volume>/lib" {
  stage
  export OUTPUT_VOLUME_FS="$SANDBOX/not-mounted"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  [[ "$output" == *"creating output in sourcevolume/lib directory"* ]]
  [ ! -d "$SANDBOX/not-mounted" ]
  [ -f "$IN/lib/api/mock.pb.h" ]
  [ -f "$IN/lib/public-api.h" ]
  [ -f "$IN/lib/CMakeLists.txt" ]
  [ -f "$IN/lib/lib/libmylib.a" ]
  [ -f "$IN/lib/include/mylib/public-api.h" ]
  # the fallback dir is created AFTER the input copy, so it never lands in $TEMP
  [ ! -d "$TEMP/lib" ]
}

@test "cpp output: a second fallback run does not re-ingest the first run's output" {
  # in fallback mode the output dir lives INSIDE the input volume, so run 2 copies
  # run 1's artifacts into the scratch tree - none of them may be compiled again
  stage
  export OUTPUT_VOLUME_FS="$SANDBOX/not-mounted"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]

  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  # the umbrella header is regenerated, not mistaken for a client-supplied one
  [[ "$output" == *"No public-api.h specified in source directory"* ]]
  # run 1's output is in the scratch copy but outside the compiled api/ tree
  [ -f "$TEMP/lib/api/mock.pb.cc" ]
  [ ! -f "$TEMP/api/mock.pb.cc.orig" ]
  # exactly this run's four stubs, no doubled nesting, no duplicated archive
  stubs=$(find "$IN/lib/api" -type f -name "*.pb.*" | grep -c . || true)
  [ "$stubs" -eq 4 ]
  [ ! -d "$IN/lib/lib/lib" ]
  [ ! -d "$IN/lib/lib/api" ]
  headers=$(find "$IN/lib/include/mylib" -type f -name "*.pb.h" | grep -c . || true)
  [ "$headers" -eq 2 ]
}

@test "cpp output: stale stubs of a deleted proto do not survive in the output volume" {
  mkdir -p "$OUT/api" "$OUT/include/mylib" "$OUT/lib/cmake/mylib"
  : > "$OUT/api/deleted_service.pb.h"
  : > "$OUT/api/deleted_service.pb.cc"
  : > "$OUT/api/deleted_service.grpc.pb.h"
  : > "$OUT/include/mylib/deleted_service.pb.h"
  printf 'stale package config\n' > "$OUT/lib/cmake/mylib/deleted-extra.cmake"
  printf 'stale archive\n' > "$OUT/lib/libmylib.a"
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  [ ! -f "$OUT/api/deleted_service.pb.h" ]
  [ ! -f "$OUT/api/deleted_service.pb.cc" ]
  [ ! -f "$OUT/api/deleted_service.grpc.pb.h" ]
  [ ! -f "$OUT/include/mylib/deleted_service.pb.h" ]
  [ ! -f "$OUT/lib/cmake/mylib/deleted-extra.cmake" ]
  # the archive was replaced, not left behind
  run grep -Fq "stale archive" "$OUT/lib/libmylib.a"
  [ "$status" -ne 0 ]
  [ -f "$OUT/api/mock.pb.h" ]
}

@test "cpp output: the cleanup is narrow - hand-written files in the output volume survive" {
  mkdir -p "$OUT/include/handwritten" "$OUT/lib/cmake/other_pkg" "$OUT/src"
  printf '#pragma once\n' > "$OUT/include/handwritten/client.h"
  printf 'other archive\n' > "$OUT/lib/libclient_extras.a"
  printf 'other package\n' > "$OUT/lib/cmake/other_pkg/other_pkg-config.cmake"
  printf 'int main(){}\n' > "$OUT/src/main.cpp"
  printf '# client readme\n' > "$OUT/README.md"
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  grep -Fq "#pragma once" "$OUT/include/handwritten/client.h"
  grep -Fq "other archive" "$OUT/lib/libclient_extras.a"
  grep -Fq "other package" "$OUT/lib/cmake/other_pkg/other_pkg-config.cmake"
  grep -Fq "int main(){}" "$OUT/src/main.cpp"
  grep -Fq "client readme" "$OUT/README.md"
  # ... while this run's own artifacts are there too
  [ -f "$OUT/lib/libmylib.a" ]
}

@test "cpp output: an api/ carried in from the input volume is neither compiled nor copied out" {
  mkdir -p "$IN/api"
  : > "$IN/api/ghost.pb.h"
  : > "$IN/api/ghost.pb.cc"
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  [ ! -f "$TEMP/api/ghost.pb.cc" ]
  [ ! -f "$OUT/api/ghost.pb.cc" ]
  [ ! -f "$OUT/include/mylib/ghost.pb.h" ]
  [ -f "$OUT/api/mock.pb.cc" ]
  # untouched where it came from
  [ -f "$IN/api/ghost.pb.cc" ]
}

# -------------------------------------------------- build files & entry point

@test "cpp build files: the defaults are copied in when the input volume ships none" {
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  [[ "$output" == *"No CMakeLists.txt specified in source directory"* ]]
  [[ "$output" == *"No ondewo-client-config.cmake.in specified in source directory"* ]]
  grep -Fq "ONDEWO_STUB_SOURCES" "$OUT/CMakeLists.txt"
  # the library name/version are injected via -D, never hard-coded in the template
  run grep -Fq "mylib" "$OUT/CMakeLists.txt"
  [ "$status" -ne 0 ]
}

@test "cpp build files: a CMakeLists.txt shipped in the input volume replaces the default" {
  printf '# hand written by the client\nproject(client)\n' > "$IN/CMakeLists.txt"
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  grep -Fq "hand written by the client" "$TEMP/CMakeLists.txt"
  grep -Fq "hand written by the client" "$OUT/CMakeLists.txt"
  run grep -Fq "ONDEWO_STUB_SOURCES" "$OUT/CMakeLists.txt"
  [ "$status" -ne 0 ]
}

@test "cpp build files: an existing output-volume build file is never clobbered" {
  printf '# the client repo root CMakeLists\n' > "$OUT/CMakeLists.txt"
  printf '# the client package config template\n' > "$OUT/ondewo-client-config.cmake.in"
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  grep -Fq "the client repo root CMakeLists" "$OUT/CMakeLists.txt"
  grep -Fq "the client package config template" "$OUT/ondewo-client-config.cmake.in"
  # the one actually used for this build is written beside the stubs instead
  grep -Fq "ONDEWO_STUB_SOURCES" "$OUT/api/CMakeLists.txt.generated"
  [ -f "$OUT/api/ondewo-client-config.cmake.in.generated" ]
  [[ "$output" == *"keeping the client's own file"* ]]
}

@test "cpp entry point: public-api.h includes every generated header, sorted and api/-relative" {
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated public-api.h with 2 includes"* ]]
  grep -Fq '#pragma once' "$OUT/public-api.h"
  grep -Fxq '#include "mock.grpc.pb.h"' "$OUT/public-api.h"
  grep -Fxq '#include "mock.pb.h"' "$OUT/public-api.h"
  # the api/ prefix is stripped (api/ IS the include root of the library) ...
  run grep -Fq '#include "api/' "$OUT/public-api.h"
  [ "$status" -ne 0 ]
  # ... the *.pb.cc sources are not included ...
  run grep -Fq '.pb.cc' "$OUT/public-api.h"
  [ "$status" -ne 0 ]
  # ... and sorted order is stable (grpc header first)
  first_include=$(grep -n '^#include' "$OUT/public-api.h" | head -1)
  [[ "$first_include" == *"mock.grpc.pb.h"* ]]
  # the installed copy is the same file
  grep -Fxq '#include "mock.pb.h"' "$OUT/include/mylib/public-api.h"
}

@test "cpp entry point: a public-api.h from the input volume is used verbatim" {
  printf '// client owned umbrella header\n#pragma once\n' > "$IN/public-api.h"
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -eq 0 ]
  [[ "$output" == *"using it verbatim, nothing appended"* ]]
  grep -Fq "client owned umbrella header" "$OUT/public-api.h"
  run grep -Fq '#include "mock' "$OUT/public-api.h"
  [ "$status" -ne 0 ]
}

# ------------------------------------------------------- failure propagation

@test "cpp failure: a missing grpc_cpp_plugin aborts the run before cmake" {
  stage
  export GRPC_CPP_PLUGIN="$SANDBOX/nowhere/grpc_cpp_plugin"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"grpc_cpp_plugin not found"* ]]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]
  [ ! -e "$PROTOC_MOCK_LOG" ]
  [ ! -e "$CMAKE_MOCK_LOG" ]
  [ ! -d "$OUT/api" ]
}

@test "cpp failure: a failing make-lib-entry-point.sh aborts the run before cmake" {
  stage
  rm -f "$SANDBOX/image-data/default-lib-files/public-api.h"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"public-api.h' does not exist"* ]]
  [[ "$output" == *"make-lib-entry-point.sh failed"* ]]
  # protoc had already run; the package build must not have
  grep -Fq 'protoc ' "$PROTOC_MOCK_LOG"
  [ ! -e "$CMAKE_MOCK_LOG" ]
  [ ! -d "$OUT/api" ]
}

@test "cpp failure: a failing cmake configure aborts the run with its own message" {
  stage
  export CMAKE_FAIL_MATCH="-DCMAKE_BUILD_TYPE"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"'cmake' configure step failed"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
  calls=$(grep -c '^cmake ' "$CMAKE_MOCK_LOG")
  [ "$calls" -eq 1 ]
  [ ! -d "$OUT/api" ]
}

@test "cpp failure: a failing cmake --build aborts the run with its own message" {
  stage
  export CMAKE_FAIL_MATCH="--parallel"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"'cmake --build' failed"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
  [ ! -d "$OUT/api" ]
}

@test "cpp failure: a failing cmake --install aborts the run and copies nothing out" {
  stage
  export CMAKE_FAIL_MATCH="--install"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"'cmake --install' failed"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
  [ ! -d "$OUT/api" ]
  [ ! -f "$OUT/public-api.h" ]
  [ ! -f "$OUT/CMakeLists.txt" ]
}

@test "cpp failure: an install step that installs nothing is caught before the copy-back" {
  # cmake --install exits 0 but never creates the prefix: compile-stubs-2-lib.sh
  # therefore reports success while the tree the orchestrator copies out does not
  # exist at all. Without the guard the run would die in `cp -r` with a bare
  # "No such file or directory", or - worse - after the output volume was already
  # wiped of this target's previous artifacts.
  stage
  stub_silent_install_cmake none
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"the CMake install tree"* ]]
  [[ "$output" == *"does not exist - compile-stubs-2-lib.sh produced nothing to copy back"* ]]
  # the package build itself claimed success - this guard is what stopped the run
  [[ "$output" == *"DONE: Executing \"compile-stubs-2-lib.sh\""* ]]
  calls=$(grep -c '^cmake ' "$CMAKE_MOCK_LOG")
  [ "$calls" -eq 3 ]
  grep -Fxq "cmake --install $BUILD" "$CMAKE_MOCK_LOG"
  [ ! -d "$INSTALL" ]
  # nothing reached the output volume, and its existing contents were not wiped
  [ ! -d "$OUT/api" ]
  [ ! -f "$OUT/public-api.h" ]
  [ ! -f "$OUT/CMakeLists.txt" ]
  [ ! -d "$OUT/include" ]
  [ ! -d "$OUT/lib" ]
}

@test "cpp failure: an empty install tree is caught before the copy-back" {
  # the prefix directory IS created but holds no file - an install() rule that
  # matched nothing. `cp -r <empty>/* ` would fail on the unexpanded glob (or
  # copy a literal '*' file), so this is reported as its own diagnosis.
  stage
  stub_silent_install_cmake empty
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"the CMake install tree"* ]]
  [[ "$output" == *"is empty - the 'cmake --install' step installed no files"* ]]
  # ... not the "does not exist" diagnosis of the sibling guard
  [[ "$output" != *"produced nothing to copy back"* ]]
  [[ "$output" == *"DONE: Executing \"compile-stubs-2-lib.sh\""* ]]
  [ -d "$INSTALL" ]
  installed=$(find "$INSTALL" -type f | grep -c . || true)
  [ "$installed" -eq 0 ]
  [ ! -d "$OUT/api" ]
  [ ! -f "$OUT/public-api.h" ]
  [ ! -f "$OUT/CMakeLists.txt" ]
  [ ! -e "$OUT/lib/libmylib.a" ]
}

@test "cpp failure: an install guard leaves a populated output volume untouched" {
  # the copy-back wipes this target's own artifacts BEFORE copying - so aborting
  # after that wipe would leave a client with neither the old nor the new library
  mkdir -p "$OUT/api" "$OUT/include/mylib" "$OUT/lib/cmake/mylib"
  printf 'previous stub\n' > "$OUT/api/previous.pb.h"
  printf 'previous header\n' > "$OUT/include/mylib/previous.pb.h"
  printf 'previous archive\n' > "$OUT/lib/libmylib.a"
  stage
  stub_silent_install_cmake none
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  grep -Fq "previous stub" "$OUT/api/previous.pb.h"
  grep -Fq "previous header" "$OUT/include/mylib/previous.pb.h"
  grep -Fq "previous archive" "$OUT/lib/libmylib.a"
}

@test "cpp failure: a missing input volume fails loudly" {
  stage
  export INPUT_VOLUME_FS="$SANDBOX/never-mounted"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"the input volume"* ]]
  [[ "$output" == *"does not exist"* ]]
  [ ! -e "$PROTOC_MOCK_LOG" ]
}

@test "cpp failure: an empty input volume fails loudly" {
  mkdir -p "$SANDBOX/empty-input"
  stage
  export INPUT_VOLUME_FS="$SANDBOX/empty-input"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to copy the contents of the input volume"* ]]
  [ ! -e "$CMAKE_MOCK_LOG" ]
}

@test "cpp failure: a wrong IMAGE_DATA_DIRECTORY is reported, not silently ignored" {
  stage
  mkdir -p "$SANDBOX/bare-image-data"
  export IMAGE_DATA_DIRECTORY="$SANDBOX/bare-image-data"
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"default library files directory"* ]]
  [ ! -e "$PROTOC_MOCK_LOG" ]
}

# ---------------------------------------------------------- the no-protos guard

@test "cpp guard: an empty protos dir fails loudly and never runs the package build" {
  rm -f "$IN/protos/library/test.proto" "$IN/protos/dependency/myimport.proto" \
        "$IN/protos/google/api/annotations.proto" "$IN/protos/other/unused.proto"
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found"* ]]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]
  [ ! -e "$PROTOC_MOCK_LOG" ]
  [ ! -e "$CMAKE_MOCK_LOG" ]
  [ ! -d "$OUT/api" ]
}

@test "cpp guard: a protos root that does not exist fails loudly" {
  stage
  run bash ./compile-proto-2-cpp.sh no-such-dir "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"the protos root directory"* ]]
  [[ "$output" == *"does not exist"* ]]
  [ ! -e "$CMAKE_MOCK_LOG" ]
}

@test "cpp guard: a protos root of api/ is rejected up front with an accurate message" {
  # api/ is the name this target owns end to end: the stubs are generated into
  # <scratch>/api, an api/ carried in from the input volume is wiped before that,
  # and the copy-back wipes <output volume>/api. Protos living there used to be
  # deleted by that scratch cleanup and the run then aborted with the WRONG
  # diagnosis ("the protos root directory does not exist").
  mkdir -p "$IN/api/library"
  printf 'syntax = "proto3";\npackage library;\nmessage A { string x = 1; }\n' \
    > "$IN/api/library/a.proto"
  stage
  run bash ./compile-proto-2-cpp.sh api "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"collides with 'api/'"* ]]
  # not the misleading message of the old behaviour
  [[ "$output" != *"the protos root directory"* ]]
  # the guard fires before the input copy, so nothing was copied or removed
  [ ! -d "$TEMP" ]
  [ ! -e "$PROTOC_MOCK_LOG" ]
  [ ! -e "$CMAKE_MOCK_LOG" ]
  [ -f "$IN/api/library/a.proto" ]
  [ ! -d "$OUT/api" ]
}

@test "cpp guard: the api/ collision guard also catches './api', 'api/' and sub-paths" {
  mkdir -p "$IN/api/library"
  printf 'syntax = "proto3";\npackage library;\nmessage A { string x = 1; }\n' \
    > "$IN/api/library/a.proto"
  stage
  for spelling in ./api api/ api/library; do
    run bash ./compile-proto-2-cpp.sh "$spelling" "" mylib
    [ "$status" -ne 0 ]
    [[ "$output" == *"collides with 'api/'"* ]]
  done
  [ -f "$IN/api/library/a.proto" ]
  [ ! -d "$TEMP" ]
  [ ! -e "$PROTOC_MOCK_LOG" ]
}

@test "cpp guard: a target subdir that does not exist fails loudly" {
  stage
  run bash ./compile-proto-2-cpp.sh protos no-such-subdir mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"the protos source directory"* ]]
  [ ! -e "$CMAKE_MOCK_LOG" ]
}

@test "cpp guard: the no-protos check is not fooled by '.proto' inside a directory name" {
  # the historical regression the sibling targets guard against: counting matches
  # of the substring ".proto" in a directory listing instead of real files
  mkdir -p "$IN/protos/dir.protos"
  rm -f "$IN/protos/library/test.proto" "$IN/protos/dependency/myimport.proto" \
        "$IN/protos/google/api/annotations.proto" "$IN/protos/other/unused.proto"
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found"* ]]
  [ ! -e "$PROTOC_MOCK_LOG" ]
}

@test "cpp guard: a DIRECTORY named *.proto does not satisfy the no-protos check" {
  mkdir -p "$IN/protos/library/nested.proto"
  rm -f "$IN/protos/library/test.proto" "$IN/protos/dependency/myimport.proto" \
        "$IN/protos/google/api/annotations.proto" "$IN/protos/other/unused.proto"
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found"* ]]
}

@test "cpp guard: a DIRECTORY named *.proto still aborts loudly without building a library" {
  # pins the CURRENT behaviour of the case above: whatever the diagnosis, nothing
  # may be written to the output volume and the package build must not run
  mkdir -p "$IN/protos/library/nested.proto"
  rm -f "$IN/protos/library/test.proto" "$IN/protos/dependency/myimport.proto" \
        "$IN/protos/google/api/annotations.proto" "$IN/protos/other/unused.proto"
  stage
  run bash ./compile-proto-2-cpp.sh protos "" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]
  [ ! -e "$CMAKE_MOCK_LOG" ]
  [ ! -d "$OUT/api" ]
  [ ! -f "$OUT/public-api.h" ]
}

# ------------------------------------------------- sub-scripts, driven directly

@test "cpp stubs unit: missing arguments produce the usage error" {
  run bash "$REPO_ROOT/cpp/image-data/compile-proto-2-stubs.sh" "$SANDBOX/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-proto-2-stubs.sh"* ]]
  [ ! -e "$PROTOC_MOCK_LOG" ]
}

@test "cpp stubs unit: a protoc that generates nothing is reported, not passed downstream" {
  SRC="$SANDBOX/protos"; mkdir -p "$SRC"
  printf 'syntax = "proto3";\nmessage A {}\n' > "$SRC/a.proto"
  export GRPC_CPP_PLUGIN=grpc_cpp_plugin
  # a protoc that exits 0 without writing any stub: the post-generation count is
  # the only thing standing between that and a library built from nothing
  mkdir -p "$SANDBOX/silent-bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/silent-bin/protoc"
  chmod +x "$SANDBOX/silent-bin/protoc"
  export PATH="$SANDBOX/silent-bin:$PATH"
  run bash "$REPO_ROOT/cpp/image-data/compile-proto-2-stubs.sh" "$SANDBOX/stubs" "$SRC" "$SRC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"produced no '*.pb.cc' sources"* ]]
}

@test "cpp stubs unit: a DIRECTORY named *.pb.cc does not pass the post-generation guard" {
  SRC="$SANDBOX/protos"; mkdir -p "$SRC" "$SANDBOX/stubs/ghost.pb.cc"
  printf 'syntax = "proto3";\nmessage A {}\n' > "$SRC/a.proto"
  export GRPC_CPP_PLUGIN=grpc_cpp_plugin
  mkdir -p "$SANDBOX/silent-bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/silent-bin/protoc"
  chmod +x "$SANDBOX/silent-bin/protoc"
  export PATH="$SANDBOX/silent-bin:$PATH"
  run bash "$REPO_ROOT/cpp/image-data/compile-proto-2-stubs.sh" "$SANDBOX/stubs" "$SRC" "$SRC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"produced no '*.pb.cc' sources"* ]]
}

@test "cpp lib unit: missing arguments produce the usage error" {
  run bash "$REPO_ROOT/cpp/image-data/compile-stubs-2-lib.sh" "$SANDBOX/src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-stubs-2-lib.sh"* ]]
  [ ! -e "$CMAKE_MOCK_LOG" ]
}

@test "cpp lib unit: a source directory that does not exist is reported" {
  # both arguments are given, so the usage guard passes; the tree they point at
  # is the thing that is missing (a mis-set TEMP_SRC_DIRECTORY, or the script run
  # by hand from the wrong place). Reported as such, and not confused with the
  # next guard's "no CMakeLists.txt in ..." - which is what a bare `-f` check on
  # the build file would have said about a whole missing tree.
  export BUILD_DIRECTORY="$SANDBOX/b" INSTALL_DIRECTORY="$SANDBOX/i"
  run bash "$REPO_ROOT/cpp/image-data/compile-stubs-2-lib.sh" "$SANDBOX/no-such-src" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"the source directory"* ]]
  [[ "$output" == *"no-such-src' does not exist"* ]]
  [[ "$output" != *"no CMakeLists.txt in"* ]]
  # the guard fires before the build: nothing was configured, built or wiped
  [ ! -e "$CMAKE_MOCK_LOG" ]
  [ ! -d "$SANDBOX/b" ]
  [ ! -d "$SANDBOX/i" ]
  [[ "$output" != *"Starting cpp build process"* ]]
}

@test "cpp lib unit: a source tree without CMakeLists.txt is reported" {
  mkdir -p "$SANDBOX/src/api"
  : > "$SANDBOX/src/api/x.pb.cc"
  run bash "$REPO_ROOT/cpp/image-data/compile-stubs-2-lib.sh" "$SANDBOX/src" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"no CMakeLists.txt in"* ]]
  [ ! -e "$CMAKE_MOCK_LOG" ]
}

@test "cpp lib unit: a source tree without generated sources is reported" {
  mkdir -p "$SANDBOX/src"
  : > "$SANDBOX/src/CMakeLists.txt"
  export BUILD_DIRECTORY="$SANDBOX/b" INSTALL_DIRECTORY="$SANDBOX/i"
  run bash "$REPO_ROOT/cpp/image-data/compile-stubs-2-lib.sh" "$SANDBOX/src" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"no generated '*.pb.cc' sources"* ]]
  [ ! -e "$CMAKE_MOCK_LOG" ]
}

@test "cpp lib unit: a *.pb.cc outside api/ does not satisfy the generated-sources guard" {
  # the source tree is a verbatim copy of the input volume, so a stub a client
  # vendors anywhere in it (checked-in generated code, a sample, a previous run's
  # output kept in src/lib/) must not stand in for what THIS run generated - the
  # CMakeLists only ever globs api/
  mkdir -p "$SANDBOX/src/vendor"
  : > "$SANDBOX/src/CMakeLists.txt"
  : > "$SANDBOX/src/vendor/checked_in.pb.cc"
  export BUILD_DIRECTORY="$SANDBOX/b" INSTALL_DIRECTORY="$SANDBOX/i"
  run bash "$REPO_ROOT/cpp/image-data/compile-stubs-2-lib.sh" "$SANDBOX/src" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"no generated '*.pb.cc' sources"* ]]
  [ ! -e "$CMAKE_MOCK_LOG" ]
}

@test "cpp lib unit: a DIRECTORY named *.pb.cc under api/ does not satisfy the guard" {
  mkdir -p "$SANDBOX/src/api/ghost.pb.cc"
  : > "$SANDBOX/src/CMakeLists.txt"
  export BUILD_DIRECTORY="$SANDBOX/b" INSTALL_DIRECTORY="$SANDBOX/i"
  run bash "$REPO_ROOT/cpp/image-data/compile-stubs-2-lib.sh" "$SANDBOX/src" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"no generated '*.pb.cc' sources"* ]]
  [ ! -e "$CMAKE_MOCK_LOG" ]
}

@test "cpp lib unit: a missing cmake is reported rather than failing obscurely" {
  mkdir -p "$SANDBOX/src" "$SANDBOX/no-tools"
  : > "$SANDBOX/src/CMakeLists.txt"
  bash_bin="$(command -v bash)"
  # PATH without any cmake at all (the guard runs before the first external call)
  run env PATH="$SANDBOX/no-tools" "$bash_bin" \
    "$REPO_ROOT/cpp/image-data/compile-stubs-2-lib.sh" "$SANDBOX/src" mylib
  [ "$status" -ne 0 ]
  [[ "$output" == *"cmake not found on PATH"* ]]
}

@test "cpp entry point unit: the argument and source-tree guards fire" {
  run bash "$REPO_ROOT/cpp/image-data/make-lib-entry-point.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no source directory given"* ]]

  run bash "$REPO_ROOT/cpp/image-data/make-lib-entry-point.sh" "$SANDBOX/nope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "cpp entry point unit: a source tree with no api/ or no headers is reported" {
  mkdir -p "$SANDBOX/src"
  run bash "$REPO_ROOT/cpp/image-data/make-lib-entry-point.sh" "$SANDBOX/src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no 'api' directory"* ]]

  rm -f "$SANDBOX/src/public-api.h"
  mkdir -p "$SANDBOX/src/api"
  : > "$SANDBOX/src/api/only-a-source.pb.cc"
  run bash "$REPO_ROOT/cpp/image-data/make-lib-entry-point.sh" "$SANDBOX/src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no generated '*.pb.h' headers"* ]]
}

@test "cpp entry point unit: nested stub headers keep their api/-relative path" {
  mkdir -p "$SANDBOX/src/api/ondewo/nlu"
  : > "$SANDBOX/src/api/ondewo/nlu/session.pb.h"
  : > "$SANDBOX/src/api/ondewo/nlu/session.grpc.pb.h"
  run bash "$REPO_ROOT/cpp/image-data/make-lib-entry-point.sh" "$SANDBOX/src"
  [ "$status" -eq 0 ]
  grep -Fxq '#include "ondewo/nlu/session.pb.h"' "$SANDBOX/src/public-api.h"
  grep -Fxq '#include "ondewo/nlu/session.grpc.pb.h"' "$SANDBOX/src/public-api.h"
}

@test "cpp entry point unit: a DIRECTORY named *.pb.h is never turned into an #include" {
  # the worst failure shape this target can ship: the include names a directory,
  # nothing in the image complains, and the breakage surfaces in the CONSUMER's
  # compiler
  mkdir -p "$SANDBOX/src/api/ghost.pb.h"
  : > "$SANDBOX/src/api/real.pb.h"
  run bash "$REPO_ROOT/cpp/image-data/make-lib-entry-point.sh" "$SANDBOX/src"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Generated public-api.h with 1 includes"* ]]
  grep -Fxq '#include "real.pb.h"' "$SANDBOX/src/public-api.h"
  run grep -Fq 'ghost.pb.h' "$SANDBOX/src/public-api.h"
  [ "$status" -ne 0 ]
}

@test "cpp entry point unit: a DIRECTORY named *.pb.h alone fails the no-headers guard" {
  mkdir -p "$SANDBOX/src/api/ghost.pb.h"
  run bash "$REPO_ROOT/cpp/image-data/make-lib-entry-point.sh" "$SANDBOX/src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no generated '*.pb.h' headers"* ]]
}

# ------------------------------------------- the resolver library's generic API
# dependecy-resolver.sh has no main (its only top-level call is commented out):
# compile-proto-2-stubs.sh `.`-sources it and calls echoProtoDependencies, and so
# do these two cases, against the cpp copy (tests/dependency_resolver.bats drives
# the byte-identical js one the same way).
#
# Both branches below are out of reach of the pipeline cases above, by
# construction rather than by omission: the orchestrated path always feeds the
# resolver find(1) output - paths that ARE files - and always through
# echoProtoDependencies, which hardcodes a non-empty exclude regex. They are the
# contract of the generic entry point, so they are pinned here.

@test "cpp resolver: an entry path that is not a file is read relative to the proto root" {
  source "$REPO_ROOT/cpp/image-data/dependecy-resolver.sh"
  ROOT="$SANDBOX/protos"
  mkdir -p "$ROOT/library" "$ROOT/dependency"
  printf 'syntax = "proto3";\nimport "dependency/myimport.proto";\nmessage T { string x = 1; }\n' \
    > "$ROOT/library/test.proto"
  printf 'syntax = "proto3";\nmessage M { string x = 1; }\n' \
    > "$ROOT/dependency/myimport.proto"
  # from a working directory where "library/test.proto" names nothing, so the
  # entry can only be understood as root-relative
  cd "$SANDBOX"
  [ ! -e "library/test.proto" ]

  run echoProtoDependencies "$ROOT" "library/test.proto"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$SANDBOX/closure.txt"
  # the entry resolved, and its import resolved from it
  grep -Fxq "library/test.proto" "$SANDBOX/closure.txt"
  grep -Fxq "dependency/myimport.proto" "$SANDBOX/closure.txt"
  # the closure stays root-relative - that is the spelling protoc is handed
  run grep -Fq "$ROOT" "$SANDBOX/closure.txt"
  [ "$status" -ne 0 ]
}

@test "cpp resolver: an empty exclude regex excludes nothing, not everything" {
  source "$REPO_ROOT/cpp/image-data/dependecy-resolver.sh"
  ROOT="$SANDBOX/protos"
  mkdir -p "$ROOT/library" "$ROOT/dependency" "$ROOT/google/protobuf"
  printf 'syntax = "proto3";\nimport "google/protobuf/timestamp.proto";\nimport "dependency/myimport.proto";\nmessage T { string x = 1; }\n' \
    > "$ROOT/library/test.proto"
  printf 'syntax = "proto3";\nmessage Timestamp { int64 s = 1; }\n' \
    > "$ROOT/google/protobuf/timestamp.proto"
  printf 'syntax = "proto3";\nmessage M { string x = 1; }\n' \
    > "$ROOT/dependency/myimport.proto"

  # `grep -E ""` matches EVERY import, so an empty exclusion list would silently
  # drop the whole closure - and protoc would be handed the entry protos only
  run echoDependencies "$ROOT" "$ROOT/library/test.proto" ""
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$SANDBOX/closure-all.txt"
  grep -Fxq "library/test.proto" "$SANDBOX/closure-all.txt"
  grep -Fxq "dependency/myimport.proto" "$SANDBOX/closure-all.txt"
  grep -Fxq "google/protobuf/timestamp.proto" "$SANDBOX/closure-all.txt"

  # same tree, same call, one argument apart: the wrapper the cpp pipeline uses
  # passes "google/protobuf/" and drops exactly that one import
  run echoProtoDependencies "$ROOT" "$ROOT/library/test.proto"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$SANDBOX/closure-wkt.txt"
  grep -Fxq "library/test.proto" "$SANDBOX/closure-wkt.txt"
  grep -Fxq "dependency/myimport.proto" "$SANDBOX/closure-wkt.txt"
  run grep -Fq "google/protobuf" "$SANDBOX/closure-wkt.txt"
  [ "$status" -ne 0 ]
}

@test "cpp resolver: the extra-roots argument widens the search and fixes the spelling" {
  # the generic contract of the 3rd argument, independent of the pipeline's
  # auto-detection: an import that lives under an extra root resolves, and is
  # echoed relative to THAT root - while a file under the proto root is still
  # echoed relative to the proto root, even though the extra root is searched first
  source "$REPO_ROOT/cpp/image-data/dependecy-resolver.sh"
  ROOT="$SANDBOX/protos"
  mkdir -p "$ROOT/ondewo/survey" "$ROOT/googleapis/google/api"
  printf 'syntax = "proto3";\nimport "google/api/annotations.proto";\nimport "ondewo/survey/other.proto";\nmessage S { string x = 1; }\n' \
    > "$ROOT/ondewo/survey/survey.proto"
  printf 'syntax = "proto3";\nmessage O { string x = 1; }\n' \
    > "$ROOT/ondewo/survey/other.proto"
  printf 'syntax = "proto3";\nmessage A { string x = 1; }\n' \
    > "$ROOT/googleapis/google/api/annotations.proto"

  # without the extra root the import is unresolvable ...
  run echoProtoDependencies "$ROOT" "$ROOT/ondewo/survey/survey.proto"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to resolve dependency"* ]]

  # ... with it, the whole closure resolves
  run echoProtoDependencies "$ROOT" "$ROOT/ondewo/survey/survey.proto" "$ROOT/googleapis"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$SANDBOX/closure-extra.txt"
  grep -Fxq "ondewo/survey/survey.proto" "$SANDBOX/closure-extra.txt"
  grep -Fxq "ondewo/survey/other.proto" "$SANDBOX/closure-extra.txt"
  grep -Fxq "google/api/annotations.proto" "$SANDBOX/closure-extra.txt"
  run grep -Fq "googleapis/" "$SANDBOX/closure-extra.txt"
  [ "$status" -ne 0 ]
}

@test "cpp image contract: the Dockerfile entrypoint, workdir and plugin default match the scripts" {
  df="$REPO_ROOT/cpp/Dockerfile"
  # exec form, naming the orchestrator this suite drives
  grep -Fxq 'ENTRYPOINT ["bash","compile-proto-2-cpp.sh"]' "$df"
  # the scripts invoke their siblings as ./x.sh, so the workdir must be the
  # IMAGE_DATA_DIRECTORY default they also resolve default-lib-files under
  grep -Fxq 'WORKDIR /image-data' "$df"
  grep -Fxq 'COPY image-data/ /image-data/' "$df"
  # the plugin path the stubs script falls back to is the one the image sets
  script_default=$(sed -n 's|^GRPC_CPP_PLUGIN="${GRPC_CPP_PLUGIN:-\(.*\)}"$|\1|p' \
    "$REPO_ROOT/cpp/image-data/compile-proto-2-stubs.sh")
  [ -n "$script_default" ]
  grep -Fxq "ENV GRPC_CPP_PLUGIN=$script_default" "$df"
  # the in-script version default and the ENV that overrides it
  grep -Fxq 'ENV ONDEWO_CLIENT_VERSION=${LIB_VERSION}' "$df"
}

# ------------------------------------------------- the callers of the image
# (examples.bats covers the pre-existing targets' run-compile.sh; cpp's caller
# surface - example script + Makefile - is pinned here with the mock docker)

@test "cpp example: run-compile.sh mounts its own dir and passes the three entrypoint args" {
  cp "$REPO_ROOT/cpp/example/run-compile.sh" "$SANDBOX/run.sh"
  run sh "$SANDBOX/run.sh"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/lib" ]
  grep -Fxq "docker run -v $SANDBOX:/input-volume -v $SANDBOX/lib:/output-volume ondewo-cpp-proto-compiler protos . ondewo_example_client" \
    "$DOCKER_MOCK_LOG"
  # codegen must never be run with -it ("cannot attach stdin to a TTY")
  run grep -Fq -- " -it " "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "cpp example: -it survives only on the interactive debug branch" {
  cp "$REPO_ROOT/cpp/example/run-compile.sh" "$SANDBOX/run.sh"
  run sh "$SANDBOX/run.sh" debug
  [ "$status" -eq 0 ]
  grep -Fq -- "-it --entrypoint /bin/bash" "$DOCKER_MOCK_LOG"
}

@test "cpp Makefile: run builds CWD-relative mounts, without -it and without --user" {
  cp "$REPO_ROOT/cpp/Makefile" "$SANDBOX/Makefile"
  run make -C "$SANDBOX" run
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/lib" ]
  grep -Fq -- "-v $SANDBOX/.:/input-volume" "$DOCKER_MOCK_LOG"
  grep -Fq -- "-v $SANDBOX/lib:/output-volume" "$DOCKER_MOCK_LOG"
  grep -Fq -- "ondewo-cpp-proto-compiler protos . ondewo_grpc_client" "$DOCKER_MOCK_LOG"
  run grep -Eq -- '(^| )(-it|--user)( |$)' "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "cpp Makefile: run honours the PROTO_DIR / TARGET_DIR / LIBRARY_NAME / OUTPUT_DIR overrides" {
  cp "$REPO_ROOT/cpp/Makefile" "$SANDBOX/Makefile"
  run make -C "$SANDBOX" run PROTO_DIR=ondewo-nlu-api TARGET_DIR=ondewo \
    LIBRARY_NAME=ondewo_nlu_client OUTPUT_DIR=generated
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/generated" ]
  grep -Fq -- "-v $SANDBOX/generated:/output-volume" "$DOCKER_MOCK_LOG"
  grep -Fq -- "ondewo-cpp-proto-compiler ondewo-nlu-api ondewo ondewo_nlu_client" \
    "$DOCKER_MOCK_LOG"
}

@test "cpp Makefile: an empty TARGET_DIR still passes '.' so the library name cannot slide" {
  # an empty word would collapse in the shell and LIBRARY_NAME would land in
  # argument 2's position - i.e. be compiled as a sub-directory name
  cp "$REPO_ROOT/cpp/Makefile" "$SANDBOX/Makefile"
  run make -C "$SANDBOX" run TARGET_DIR= LIBRARY_NAME=ondewo_nlu_client
  [ "$status" -eq 0 ]
  grep -Fq -- "ondewo-cpp-proto-compiler protos . ondewo_nlu_client" "$DOCKER_MOCK_LOG"
}

@test "cpp Makefile: build tags the documented image name from the target's own dir" {
  cp "$REPO_ROOT/cpp/Makefile" "$SANDBOX/Makefile"
  run make -C "$SANDBOX" build
  [ "$status" -eq 0 ]
  grep -Fxq "docker build -t ondewo-cpp-proto-compiler ." "$DOCKER_MOCK_LOG"
}

@test "cpp stubs unit: a proto whose filename contains a newline aborts instead of compiling a mangled list" {
  # `while IFS= read -r` splits such a name into two fragments, neither of which is a
  # file. Before the resolver guard this printed "Found 3 .proto files", dropped the
  # real proto, handed protoc the bogus tail fragment and still exited 0.
  SRC="$SANDBOX/nl-protos"; mkdir -p "$SRC"
  printf 'syntax = "proto3";\nmessage A {}\n' > "$SRC/ok.proto"
  printf 'syntax = "proto3";\nmessage B {}\n' > "$SRC/$(printf 'we\nird')".proto
  export GRPC_CPP_PLUGIN=grpc_cpp_plugin
  run bash "$REPO_ROOT/cpp/image-data/compile-proto-2-stubs.sh" "$SANDBOX/nl-stubs" "$SRC" "$SRC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not a readable .proto file"* ]]
  [[ "$output" == *"dependency resolution failed"* ]]
  # nothing was compiled from the mangled list
  [ ! -s "$PROTOC_MOCK_LOG" ]
}
