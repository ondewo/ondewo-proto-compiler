#!/usr/bin/env bats
# Behavioural coverage of the `java/` proto-compiler target, driven on the HOST.
#
# The real scripts (java/image-data/compile-proto-2-java.sh and the three
# sub-scripts it calls) are executed with their container paths redirected into
# the sandbox via IMAGE_DATA_DIRECTORY / INPUT_VOLUME_FS / OUTPUT_VOLUME_FS /
# TEMP_SRC_DIRECTORY, and with `protoc` and `mvn` PATH-mocked. No docker build,
# no network, no JDK and no maven repository are involved: every assertion is
# about the scripts' own logic — which binary was called with which arguments
# (read back from the mock argv logs), which files ended up where, and that a
# failure of any stage aborts the run with a message on stderr.
#
# The pom.xml toolchain pins (GRPC_JAVA_VERSION & co.) are part of the image ENV
# in production and are scrubbed by common_setup, so every test that needs them
# exports them AFTER common_setup — with deliberately fake values, so a pin
# asserted in a generated pom can only have come from the environment and never
# from a Dockerfile default that happens to match.

load 'helpers/setup'

setup() {
  common_setup
  # Extra protoc import roots are read from the environment by
  # compile-proto-2-stubs.sh, and the name matches none of common_setup's
  # scrubbed prefixes - an ambient value would silently decide the outcome of
  # every auto-detection case below.
  unset EXTRA_PROTO_DIRS
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  export MVN_MOCK_LOG="$SANDBOX/mvn.log"
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  IN="$SANDBOX/input"
  OUT="$SANDBOX/output"
  mkdir -p "$IN/protos/library" "$OUT"
  printf 'syntax = "proto3";\npackage library;\nmessage Test {}\n' \
    > "$IN/protos/library/test.proto"
}
teardown() { common_teardown; }

# The five pom.xml template pins the image sets as ENV from its Dockerfile ARGs.
# Fake-but-well-formed values, so a match in a rendered pom proves the ENV path.
export_pom_pins() {
  export GRPC_JAVA_VERSION="1.84.0-testpin"
  export PROTOBUF_JAVA_VERSION="4.33.6-testpin"
  export GOOGLE_COMMON_PROTOS_VERSION="2.76.0-testpin"
  export MAVEN_SOURCE_PLUGIN_VERSION="3.4.0-testpin"
  export JAVA_RELEASE="17"
}

# Copy java/image-data into the sandbox (so nothing is ever written into the repo
# tree), cd there — the orchestrator invokes its siblings as ./x.sh — and point
# every container-path knob at the sandbox.
stage_java() {
  cp -r "$REPO_ROOT/java/image-data" "$SANDBOX/image-data"
  cd "$SANDBOX/image-data"
  export IMAGE_DATA_DIRECTORY="$SANDBOX/image-data"
  export INPUT_VOLUME_FS="$IN"
  export OUTPUT_VOLUME_FS="$OUT"
  export MAVEN_REPO_LOCAL="$SANDBOX/m2"
  # TEMP_SRC_DIRECTORY is left at its derived default on purpose (one test below
  # asserts the override is honoured); these are where it lands.
  TMPSRC="$SANDBOX/image-data/src"
  MAVENPROJ="${TMPSRC}-maven-project"
  STUBS="$MAVENPROJ/src/main/java"
  export_pom_pins
}

# Run the orchestrator with stdout/stderr split, so "fails loudly on stderr" is a
# real assertion rather than a claim about bats' merged $output.
run_orchestrator() {
  run bash -c 'bash ./compile-proto-2-java.sh "$@" \
      >"$SANDBOX/stdout.txt" 2>"$SANDBOX/stderr.txt"' _ "$@"
}

# cksum-per-file snapshot of a tree; content-based, so it is immune to the mtime
# churn `cp -r` causes and works identically on GNU and BSD userlands.
tree_digest() {
  find "$1" -type f -exec cksum {} \; | sort
}

# Same split-stream treatment for the two sub-scripts that are also documented
# entry points of their own (the orchestrator calls them as ./x.sh).
run_stubs() {
  run bash -c 'bash "$SANDBOX/image-data/compile-proto-2-stubs.sh" "$@" \
      >"$SANDBOX/stdout.txt" 2>"$SANDBOX/stderr.txt"' _ "$@"
}
run_entry_point_split() {
  run bash -c 'bash "$SANDBOX/image-data/make-lib-entry-point.sh" "$@" \
      >"$SANDBOX/stdout.txt" 2>"$SANDBOX/stderr.txt"' _ "$@"
}

# A protoc that exits 0 and writes nothing at all - which is exactly the case the
# post-condition in compile-proto-2-stubs.sh exists for ("protoc exits 0 on an
# empty input set in some versions"). It shadows the suite's protoc mock by
# taking precedence on PATH and keeps appending to the same argv log, so "protoc
# really was invoked, and it is the post-condition that failed the run" stays
# assertable rather than being indistinguishable from an earlier guard.
stub_silent_protoc() {
  mkdir -p "$SANDBOX/silent-bin"
  cat > "$SANDBOX/silent-bin/protoc" <<'SILENT_PROTOC'
#!/usr/bin/env bash
: "${PROTOC_MOCK_LOG:=/dev/null}"
printf 'protoc %s\n' "$*" >> "$PROTOC_MOCK_LOG"
exit 0
SILENT_PROTOC
  chmod +x "$SANDBOX/silent-bin/protoc"
  PATH="$SANDBOX/silent-bin:$PATH"
  export PATH
}

# Simulate the one thing that can put an unsubstituted @PLACEHOLDER@ into a
# rendered pom.xml: the template growing a field make-lib-entry-point.sh has no
# `-e s|@…@|` for. Only the sandbox copy of the template is touched, and the new
# field is placed INSIDE <project>, where a real new pin would sit.
add_unknown_template_placeholder() {
  local tmpl="$SANDBOX/image-data/default-lib-files/pom.xml"
  awk '/<\/project>/ && !ins { print "  <new.pin.version>@NEW_TOOLCHAIN_PIN@</new.pin.version>"; ins = 1 } { print }' \
    "$tmpl" > "$tmpl.new"
  mv "$tmpl.new" "$tmpl"
}

# ------------------------------------------------------------------ end to end

@test "java e2e: the full pipeline writes the documented maven project to the output volume" {
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  # build descriptor + license
  [ -f "$OUT/pom.xml" ]
  [ -f "$OUT/LICENSE" ]
  # generated stubs, nested in their java package directories
  [ -f "$OUT/src/main/java/com/ondewo/mock/Test.java" ]
  [ -f "$OUT/src/main/java/com/ondewo/mock/TestOrBuilder.java" ]
  [ -f "$OUT/src/main/java/com/ondewo/mock/TestGrpc.java" ]
  # the packaged artifacts, named after the default maven coordinates
  [ -f "$OUT/target/ondewo-proto-stubs-java-0.0.0.jar" ]
  [ -f "$OUT/target/ondewo-proto-stubs-java-0.0.0-sources.jar" ]
  # ... and ONLY the artifacts: the target/ scratch tree must not be shipped
  [ ! -d "$OUT/target/classes" ]
}

@test "java e2e: compilation happens on the temp copy, the mounted input volume is never mutated" {
  # a proto carrying the Dialogflow-inherited java_package, which the orchestrator
  # rewrites - the single most destructive thing it does to a .proto file.
  printf 'syntax = "proto3";\npackage library;\noption java_package = "com.google.cloud.dialogflow.v2";\nmessage Legacy {}\n' \
    > "$IN/protos/library/legacy.proto"
  stage_java

  before="$(tree_digest "$IN")"
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  after="$(tree_digest "$IN")"
  [ "$before" = "$after" ]

  # the mounted original still carries the google namespace ...
  grep -Fq 'option java_package = "com.google.cloud.dialogflow.v2";' "$IN/protos/library/legacy.proto"
  # ... while the copy compiled from was rewritten to the ondewo one
  grep -Fq 'option java_package = "com.ondewo.nlu";' "$TMPSRC/protos/library/legacy.proto"
}

@test "java e2e: the java_package rewrite skips the vendored google/ tree" {
  # A googleapis checkout carries google/cloud/dialogflow/v2/*.proto, whose
  # java_package IS the literal the orchestrator replaces. Rewriting Google's own
  # files would repackage them into com.ondewo.nlu, so an ondewo proto importing
  # one would generate references to classes no jar provides.
  mkdir -p "$IN/protos/google/cloud/dialogflow/v2"
  printf 'syntax = "proto3";\npackage google.cloud.dialogflow.v2;\noption java_package = "com.google.cloud.dialogflow.v2";\nmessage Session {}\n' \
    > "$IN/protos/google/cloud/dialogflow/v2/session.proto"
  printf 'syntax = "proto3";\npackage library;\noption java_package = "com.google.cloud.dialogflow.v2";\nmessage Legacy {}\n' \
    > "$IN/protos/library/legacy.proto"
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  # the ondewo-side proto is rewritten ...
  grep -Fq 'option java_package = "com.ondewo.nlu";' "$TMPSRC/protos/library/legacy.proto"
  # ... while the vendored google/ one keeps its own namespace, untouched
  grep -Fq 'option java_package = "com.google.cloud.dialogflow.v2";' \
    "$TMPSRC/protos/google/cloud/dialogflow/v2/session.proto"
  # and no sed backup was made below google/ either
  run bash -c 'find "$SANDBOX/image-data/src/protos/google" -name "*.bak" | grep -c . || true'
  [ "$output" = "0" ]
}

@test "java e2e: the sed -i.bak java_package rewrite leaves no .bak files behind" {
  printf 'syntax = "proto3";\npackage library;\noption java_package = "com.google.cloud.dialogflow.v2";\nmessage Legacy {}\n' \
    > "$IN/protos/library/legacy.proto"
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  run bash -c 'find "$SANDBOX/image-data/src" -name "*.bak" | grep -c . || true'
  [ "$output" = "0" ]
}

@test "java e2e: TEMP_SRC_DIRECTORY override is honoured (nothing lands under image-data)" {
  stage_java
  export TEMP_SRC_DIRECTORY="$SANDBOX/elsewhere"
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/elsewhere-maven-project/pom.xml" ]
  [ ! -e "$SANDBOX/image-data/src" ]
  [ ! -e "$SANDBOX/image-data/src-maven-project" ]
}

@test "java e2e: a missing output volume falls back to <input volume>/lib" {
  stage_java
  export OUTPUT_VOLUME_FS="$SANDBOX/does-not-exist"
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  [[ "$output" == *"sourcevolume/lib"* ]]
  [ ! -d "$SANDBOX/does-not-exist" ]
  [ -f "$IN/lib/pom.xml" ]
  [ -f "$IN/lib/src/main/java/com/ondewo/mock/Test.java" ]
  [ -f "$IN/lib/target/ondewo-proto-stubs-java-0.0.0.jar" ]
}

@test "java e2e: a missing input volume fails loudly and never reaches protoc" {
  stage_java
  export INPUT_VOLUME_FS="$SANDBOX/no-such-mount"
  run_orchestrator protos library
  [ "$status" -ne 0 ]
  grep -Fq "the input volume '$SANDBOX/no-such-mount' does not exist" "$SANDBOX/stderr.txt"
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "java e2e: an empty input volume fails loudly on the copy" {
  rm -rf "$IN"; mkdir -p "$IN"
  stage_java
  run_orchestrator protos library
  [ "$status" -ne 0 ]
  grep -Fq "ERROR: failed to copy input volume contents" "$SANDBOX/stderr.txt"
}

# ------------------------------------------------------- stale output handling

@test "java stale: a stub left over for a since-deleted proto does not survive" {
  mkdir -p "$OUT/src/main/java/com/ondewo/mock"
  printf 'class Removed {}\n' > "$OUT/src/main/java/com/ondewo/mock/RemovedService.java"
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  [ ! -f "$OUT/src/main/java/com/ondewo/mock/RemovedService.java" ]
  # the stubs this run DID generate are there
  [ -f "$OUT/src/main/java/com/ondewo/mock/Test.java" ]
}

@test "java stale: a hand-written sibling package survives the narrowed sweep" {
  mkdir -p "$OUT/src/main/java/com/ondewo/auth" "$OUT/src/main/java/com/ondewo/mock"
  printf 'class TokenProvider {}\n' > "$OUT/src/main/java/com/ondewo/auth/TokenProvider.java"
  printf 'class Removed {}\n'       > "$OUT/src/main/java/com/ondewo/mock/RemovedService.java"
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  [ -f "$OUT/src/main/java/com/ondewo/auth/TokenProvider.java" ]
  [ ! -f "$OUT/src/main/java/com/ondewo/mock/RemovedService.java" ]
}

@test "java stale: a non-.java file in a regenerated package is not swept" {
  mkdir -p "$OUT/src/main/java/com/ondewo/mock"
  printf 'key=value\n' > "$OUT/src/main/java/com/ondewo/mock/messages.properties"
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  [ -f "$OUT/src/main/java/com/ondewo/mock/messages.properties" ]
}

@test "java stale: an old jar of THIS artifact is dropped, a foreign jar in target/ survives" {
  mkdir -p "$OUT/target"
  printf 'old\n'     > "$OUT/target/ondewo-proto-stubs-java-4.0.0.jar"
  printf 'foreign\n' > "$OUT/target/some-client-app-1.2.3.jar"
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  [ ! -f "$OUT/target/ondewo-proto-stubs-java-4.0.0.jar" ]
  [ -f "$OUT/target/some-client-app-1.2.3.jar" ]
  [ -f "$OUT/target/ondewo-proto-stubs-java-0.0.0.jar" ]
}

# ---------------------------------------------------------- argument handling

@test "java args: arg 1 defaults to 'protos'" {
  stage_java
  run bash ./compile-proto-2-java.sh
  [ "$status" -eq 0 ]
  grep -Fq -- "-I $TMPSRC/protos " "$PROTOC_MOCK_LOG"
  grep -Fq -- "$TMPSRC/protos/library/test.proto" "$PROTOC_MOCK_LOG"
}

@test "java args: an explicit relative protos dir becomes protoc's -I root" {
  rm -rf "$IN/protos"
  mkdir -p "$IN/vendor/api/ondewo"
  printf 'syntax = "proto3";\npackage ondewo;\nmessage A {}\n' \
    > "$IN/vendor/api/ondewo/a.proto"
  stage_java
  run bash ./compile-proto-2-java.sh vendor/api ondewo
  [ "$status" -eq 0 ]
  grep -Fq -- "-I $TMPSRC/vendor/api " "$PROTOC_MOCK_LOG"
  grep -Fq -- "$TMPSRC/vendor/api/ondewo/a.proto" "$PROTOC_MOCK_LOG"
}

@test "java args: arg 2 scopes compilation to one sub-tree, -I stays the protos root" {
  mkdir -p "$IN/protos/other"
  printf 'syntax = "proto3";\npackage other;\nmessage Other {}\n' \
    > "$IN/protos/other/other.proto"
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  # only the scoped sub-tree is compiled ...
  grep -Fq -- "$TMPSRC/protos/library/test.proto" "$PROTOC_MOCK_LOG"
  run grep -Fq -- "$TMPSRC/protos/other/other.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # ... but the import root is still the whole protos root, so a cross-tree
  # `import "other/other.proto";` keeps resolving
  grep -Fq -- "-I $TMPSRC/protos " "$PROTOC_MOCK_LOG"
}

@test "java args: a nonexistent protos root (arg 1) fails loudly before protoc" {
  stage_java
  run_orchestrator no-such-dir
  [ "$status" -ne 0 ]
  grep -Fq "the protos root directory 'no-such-dir' (arg 1) does not exist" "$SANDBOX/stderr.txt"
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "java args: a nonexistent target subdir (arg 2) fails loudly before protoc" {
  stage_java
  run_orchestrator protos no-such-subdir
  [ "$status" -ne 0 ]
  grep -Fq "the protos source directory" "$SANDBOX/stderr.txt"
  grep -Fq "no-such-subdir" "$SANDBOX/stderr.txt"
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "java args: args 3-5 set the maven coordinates of pom, jar and console summary" {
  stage_java
  run bash ./compile-proto-2-java.sh protos library com.acme acme-stubs 7.8.9
  [ "$status" -eq 0 ]

  grep -Fq "<groupId>com.acme</groupId>" "$OUT/pom.xml"
  grep -Fq "<artifactId>acme-stubs</artifactId>" "$OUT/pom.xml"
  grep -Fq "<version>7.8.9</version>" "$OUT/pom.xml"
  [ -f "$OUT/target/acme-stubs-7.8.9.jar" ]
  [[ "$output" == *"com.acme:acme-stubs:7.8.9"* ]]
}

@test "java args: the version falls back to ONDEWO_PROTO_COMPILER_VERSION, then to 0.0.0" {
  stage_java
  ONDEWO_PROTO_COMPILER_VERSION=6.1.2 run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  grep -Fq "<version>6.1.2</version>" "$OUT/pom.xml"
  [ -f "$OUT/target/ondewo-proto-stubs-java-6.1.2.jar" ]

  # with the ENV absent (common_setup scrubs it) the in-script default applies
  rm -rf "$OUT" "$SANDBOX/image-data/src"; mkdir -p "$OUT"
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  grep -Fq "<version>0.0.0</version>" "$OUT/pom.xml"
}

# ------------------------------------------------------ the protoc invocation

@test "java protoc: one single pass carries -I, both _out flags and the grpc-java plugin" {
  stage_java
  export PROTOC_GEN_GRPC_JAVA="$SANDBOX/fake-grpc-java-plugin"
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  # java has deliberately NO second "dependency" protoc pass (the google classes
  # come from jars), so exactly one invocation is the contract.
  run grep -c '^protoc ' "$PROTOC_MOCK_LOG"
  [ "$output" = "1" ]

  grep -Fq -- "--plugin=protoc-gen-grpc-java=$SANDBOX/fake-grpc-java-plugin" "$PROTOC_MOCK_LOG"
  grep -Fq -- "--java_out=$STUBS " "$PROTOC_MOCK_LOG"
  grep -Fq -- "--grpc-java_out=$STUBS " "$PROTOC_MOCK_LOG"
  grep -Fq -- "-I $TMPSRC/protos " "$PROTOC_MOCK_LOG"
}

@test "java protoc: the vendored google/ tree is an import root, never a compilation target" {
  mkdir -p "$IN/protos/google/protobuf" "$IN/protos/google/api"
  printf 'syntax = "proto3";\npackage google.protobuf;\nmessage Empty {}\n' \
    > "$IN/protos/google/protobuf/empty.proto"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Http {}\n' \
    > "$IN/protos/google/api/annotations.proto"
  stage_java
  run bash ./compile-proto-2-java.sh protos
  [ "$status" -eq 0 ]

  # nothing below google/ was handed to protoc as an input file ...
  run grep -F -- "/google/" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # ... while the ondewo protos were, and -I still spans the whole root so the
  # google imports resolve
  grep -Fq -- "$TMPSRC/protos/library/test.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- "-I $TMPSRC/protos " "$PROTOC_MOCK_LOG"
}

@test "java protoc: a vendored google/ tree does not count as a second top-level tree" {
  # ondewo-nlu-api's real shape: one tree (ondewo/) plus the always-excluded
  # google/. An unscoped run must be accepted, not refused by the multi-tree guard.
  mkdir -p "$IN/protos/google/protobuf"
  printf 'syntax = "proto3";\npackage google.protobuf;\nmessage Empty {}\n' \
    > "$IN/protos/google/protobuf/empty.proto"
  stage_java
  run bash ./compile-proto-2-java.sh protos
  [ "$status" -eq 0 ]
  [[ "$output" != *"top-level trees"* ]]
}

# ---------------------------------------------- extra protoc import roots (-I)

# ondewo-survey-api's shape, and the only one of the seven apis that has it: the
# googleapis checkout one level DOWN (googleapis/google/api/...) and no google/
# at the protos root - so `import "google/api/annotations.proto";` resolves
# against a second -I or not at all.
make_survey_layout() {
  mkdir -p "$IN/protos/googleapis/google/api"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Http {}\n' \
    > "$IN/protos/googleapis/google/api/annotations.proto"
}

# How many import roots the single protoc invocation was handed. Counted by
# splitting the logged argv on spaces and matching whole "-I" words, so a path
# that merely contains "-I" cannot inflate the count.
count_import_roots() {
  tr ' ' '\n' < "$PROTOC_MOCK_LOG" | grep -cx -- '-I' || true
}

@test "java extra-I: a survey-style googleapis/ tree becomes a second import root" {
  make_survey_layout
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  [ "$(count_import_roots)" = "2" ]
  # the protos root stays first, so a proto the api vendors itself still wins
  grep -Fq -- "-I $TMPSRC/protos -I $TMPSRC/protos/googleapis " "$PROTOC_MOCK_LOG"
  [[ "$output" == *"Extra protoc import root: $TMPSRC/protos/googleapis"* ]]
}

@test "java extra-I: a root without googleapis/ keeps protoc's single import root" {
  # the 36 combinations that already work: nothing to detect, nothing added, and
  # a command line byte-identical to the one before this knob existed.
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  [ "$(count_import_roots)" = "1" ]
  grep -Fq -- "-I $TMPSRC/protos " "$PROTOC_MOCK_LOG"
  [[ "$output" != *"Extra protoc import root"* ]]
}

@test "java extra-I: a root that vendors google/ itself gets no extra import root" {
  # nlu/csi/vtsi resolve google/* from the protos root. Even with a googleapis/
  # alongside it, the auto-detection must stay out of the way rather than add a
  # second root that shadows what the api deliberately vendored.
  make_survey_layout
  mkdir -p "$IN/protos/google/api"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Http {}\n' \
    > "$IN/protos/google/api/annotations.proto"
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  [ "$(count_import_roots)" = "1" ]
  run grep -F -- "-I $TMPSRC/protos/googleapis" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "java extra-I: EXTRA_PROTO_DIRS overrides the auto-detected default" {
  make_survey_layout
  mkdir -p "$IN/protos/vendor/gapi/google/api"
  printf 'syntax = "proto3";\npackage google.api;\nmessage Http {}\n' \
    > "$IN/protos/vendor/gapi/google/api/annotations.proto"
  stage_java
  export EXTRA_PROTO_DIRS="vendor/gapi"
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  grep -Fq -- "-I $TMPSRC/protos/vendor/gapi " "$PROTOC_MOCK_LOG"
  # the override REPLACES the detected default, it does not extend it
  [ "$(count_import_roots)" = "2" ]
  run grep -F -- "-I $TMPSRC/protos/googleapis" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "java extra-I: EXTRA_PROTO_DIRS is a list, added in the order given" {
  mkdir -p "$IN/protos/first" "$IN/protos/second"
  stage_java
  export EXTRA_PROTO_DIRS="first second"
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  [ "$(count_import_roots)" = "3" ]
  grep -Fq -- "-I $TMPSRC/protos -I $TMPSRC/protos/first -I $TMPSRC/protos/second " \
    "$PROTOC_MOCK_LOG"
}

@test "java extra-I: an absolute EXTRA_PROTO_DIRS entry is taken as-is" {
  mkdir -p "$SANDBOX/shared-protos"
  stage_java
  export EXTRA_PROTO_DIRS="$SANDBOX/shared-protos"
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  # not re-anchored on the protos root, and not doubled up with it either
  grep -Fq -- "-I $SANDBOX/shared-protos " "$PROTOC_MOCK_LOG"
  run grep -F -- "-I $TMPSRC/protos$SANDBOX" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "java extra-I: an explicit empty EXTRA_PROTO_DIRS switches auto-detection off" {
  make_survey_layout
  stage_java
  export EXTRA_PROTO_DIRS=""
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  [ "$(count_import_roots)" = "1" ]
  run grep -F -- "-I $TMPSRC/protos/googleapis" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "java extra-I: a nonexistent EXTRA_PROTO_DIRS entry is refused before protoc" {
  # the auto-detected default is produced by a `-d` test and can never name a
  # missing directory, so this can only be a typo in a caller's override -
  # refused here, instead of surfacing later as protoc's "File not found." on an
  # import, which names the import and not the import root that is missing.
  stage_java
  export EXTRA_PROTO_DIRS="no-such-vendor"
  run_orchestrator protos library
  [ "$status" -ne 0 ]

  grep -Fq "the extra protoc import root '$TMPSRC/protos/no-such-vendor'" "$SANDBOX/stderr.txt"
  grep -Fq "EXTRA_PROTO_DIRS entry" "$SANDBOX/stderr.txt"
  grep -Fq "ERROR: compile-proto-2-stubs.sh failed" "$SANDBOX/stderr.txt"
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$MVN_MOCK_LOG" ]
}

@test "java extra-I: the googleapis tree is an import root, never a compilation target" {
  make_survey_layout
  stage_java
  # Unscoped, which is what survey's real shape allows: every proto below
  # googleapis/ sits under google/, so the pre-existing exclusion keeps it out of
  # BOTH the input set and the multi-tree guard's tree count.
  run bash ./compile-proto-2-java.sh protos
  [ "$status" -eq 0 ]
  [[ "$output" != *"top-level trees"* ]]

  run grep -F -- "$TMPSRC/protos/googleapis/google/api/annotations.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  grep -Fq -- "-I $TMPSRC/protos/googleapis " "$PROTOC_MOCK_LOG"
  grep -Fq -- "$TMPSRC/protos/library/test.proto" "$PROTOC_MOCK_LOG"
}

# -------------------------------------------------------- the no-protos guard

@test "java guard: an empty protos dir fails loudly and never runs the package build" {
  rm -f "$IN/protos/library/test.proto"
  stage_java
  run_orchestrator protos library
  [ "$status" -ne 0 ]
  grep -Fq "No proto files were found" "$SANDBOX/stderr.txt"
  grep -Fq "ERROR: compile-proto-2-stubs.sh failed" "$SANDBOX/stderr.txt"
  [ ! -s "$MVN_MOCK_LOG" ]
}

@test "java guard: a DIRECTORY named *.proto does not satisfy the no-protos guard" {
  rm -f "$IN/protos/library/test.proto"
  mkdir -p "$IN/protos/library/vendor.proto"
  printf 'not a proto\n' > "$IN/protos/library/vendor.proto/readme.txt"
  stage_java
  run_orchestrator protos library
  [ "$status" -ne 0 ]
  grep -Fq "No proto files were found" "$SANDBOX/stderr.txt"
}

@test "java guard: an unscoped multi-tree protos root is refused and names the trees" {
  rm -rf "$IN/protos"
  mkdir -p "$IN/protos/treeone" "$IN/protos/treetwo"
  printf 'syntax = "proto3";\npackage one;\nmessage A {}\n' > "$IN/protos/treeone/a.proto"
  printf 'syntax = "proto3";\npackage two;\nmessage B {}\n' > "$IN/protos/treetwo/b.proto"
  stage_java
  run_orchestrator protos
  [ "$status" -ne 0 ]
  grep -Fq "spans 2 top-level trees" "$SANDBOX/stderr.txt"
  grep -Fq "treeone" "$SANDBOX/stderr.txt"
  grep -Fq "treetwo" "$SANDBOX/stderr.txt"
  # refused BEFORE protoc ran, and the package build never started
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$MVN_MOCK_LOG" ]
}

@test "java guard: the same multi-tree root compiles once a target subdir scopes it" {
  rm -rf "$IN/protos"
  mkdir -p "$IN/protos/treeone" "$IN/protos/treetwo"
  printf 'syntax = "proto3";\npackage one;\nmessage A {}\n' > "$IN/protos/treeone/a.proto"
  printf 'syntax = "proto3";\npackage two;\nmessage B {}\n' > "$IN/protos/treetwo/b.proto"
  stage_java
  run bash ./compile-proto-2-java.sh protos treeone
  [ "$status" -eq 0 ]
  grep -Fq -- "$TMPSRC/protos/treeone/a.proto" "$PROTOC_MOCK_LOG"
  run grep -Fq -- "$TMPSRC/protos/treetwo/b.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "java guard: a trailing slash on arg 1 must not bypass the multi-tree guard" {
  rm -rf "$IN/protos"
  mkdir -p "$IN/protos/treeone" "$IN/protos/treetwo"
  printf 'syntax = "proto3";\npackage one;\nmessage A {}\n' > "$IN/protos/treeone/a.proto"
  printf 'syntax = "proto3";\npackage two;\nmessage B {}\n' > "$IN/protos/treetwo/b.proto"
  stage_java
  run_orchestrator 'protos/'
  [ "$status" -ne 0 ]
  grep -Fq "spans 2 top-level trees" "$SANDBOX/stderr.txt"
}

# ------------------------------------------------------- failure propagation

@test "java failure: compile-proto-2-stubs.sh failing aborts the orchestrator on stderr" {
  rm -f "$IN/protos/library/test.proto"
  stage_java
  run_orchestrator protos library
  [ "$status" -ne 0 ]
  grep -Fq "ERROR: compile-proto-2-stubs.sh failed" "$SANDBOX/stderr.txt"
  # the success banner is never printed
  run grep -Fq "compilation finished successfully" "$SANDBOX/stdout.txt"
  [ "$status" -ne 0 ]
}

@test "java failure: make-lib-entry-point.sh failing aborts before the package build" {
  stage_java
  unset GRPC_JAVA_VERSION
  run_orchestrator protos library
  [ "$status" -ne 0 ]
  grep -Fq "GRPC_JAVA_VERSION" "$SANDBOX/stderr.txt"
  grep -Fq "ERROR: make-lib-entry-point.sh failed" "$SANDBOX/stderr.txt"
  # protoc DID run (the stubs come first), maven never did
  [ -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$MVN_MOCK_LOG" ]
}

@test "java failure: a failing maven build aborts the orchestrator and copies nothing out" {
  stage_java
  export MVN_FAIL_MATCH="package"
  export MVN_FAIL_RC=2
  run_orchestrator protos library
  [ "$status" -ne 0 ]
  grep -Fq "ERROR: compile-stubs-2-lib.sh failed" "$SANDBOX/stderr.txt"
  [ ! -f "$OUT/pom.xml" ]
  [ ! -d "$OUT/target" ]
}

@test "java failure: maven exiting 0 without a target/ directory is caught, not shipped" {
  stage_java
  # the mock short-circuits on the match; rc 0 makes it "succeed" silently
  export MVN_FAIL_MATCH="package"
  export MVN_FAIL_RC=0
  run_orchestrator protos library
  [ "$status" -ne 0 ]
  grep -Fq "the maven build produced no" "$SANDBOX/stderr.txt"
  grep -Fq "ERROR: compile-stubs-2-lib.sh failed" "$SANDBOX/stderr.txt"
}

# ----------------------------------------- pom rendering (make-lib-entry-point)

# make-lib-entry-point.sh resolves its template from $IMAGE_DATA_DIRECTORY, so it
# can be unit-driven from anywhere once the image-data tree is staged.
run_entry_point() {
  run bash "$SANDBOX/image-data/make-lib-entry-point.sh" "$@"
}

@test "java pom: every placeholder is substituted from the args and the image ENV" {
  stage_java
  PROJ="$SANDBOX/proj"
  run_entry_point "$PROJ" com.acme acme-stubs 7.8.9
  [ "$status" -eq 0 ]

  grep -Fq "<groupId>com.acme</groupId>"           "$PROJ/pom.xml"
  grep -Fq "<artifactId>acme-stubs</artifactId>"   "$PROJ/pom.xml"
  grep -Fq "<version>7.8.9</version>"              "$PROJ/pom.xml"
  grep -Fq "<name>acme-stubs</name>"               "$PROJ/pom.xml"
  grep -Fq "<maven.compiler.release>17</maven.compiler.release>" "$PROJ/pom.xml"
  grep -Fq "<grpc.version>1.84.0-testpin</grpc.version>"             "$PROJ/pom.xml"
  grep -Fq "<protobuf.version>4.33.6-testpin</protobuf.version>"     "$PROJ/pom.xml"
  grep -Fq "<google.common.protos.version>2.76.0-testpin</google.common.protos.version>" "$PROJ/pom.xml"
  grep -Fq "<version>3.4.0-testpin</version>"      "$PROJ/pom.xml"

  # no unsubstituted @PLACEHOLDER@ survives
  run grep -c '@[A-Z_]\{1,\}@' "$PROJ/pom.xml"
  [ "$output" = "0" ]
}

@test "java pom: each required toolchain pin is checked by name when empty" {
  stage_java
  for pin in GRPC_JAVA_VERSION PROTOBUF_JAVA_VERSION GOOGLE_COMMON_PROTOS_VERSION \
             MAVEN_SOURCE_PLUGIN_VERSION JAVA_RELEASE; do
    export_pom_pins
    export "$pin="
    PROJ="$SANDBOX/proj-$pin"
    run_entry_point "$PROJ" com.acme acme-stubs 7.8.9
    [ "$status" -ne 0 ]
    [[ "$output" == *"$pin"* ]]
    [ ! -f "$PROJ/pom.xml" ]
  done
}

@test "java pom: incomplete maven coordinates are refused" {
  stage_java
  run_entry_point "$SANDBOX/proj" com.acme "" 7.8.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"coordinates are incomplete"* ]]

  run_entry_point
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: make-lib-entry-point.sh"* ]]
}

@test "java pom: a missing template fails loudly instead of shipping an empty pom" {
  stage_java
  rm -f "$SANDBOX/image-data/default-lib-files/pom.xml"
  PROJ="$SANDBOX/proj"
  run_entry_point "$PROJ" com.acme acme-stubs 7.8.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"template"* ]]
  [ ! -f "$PROJ/pom.xml" ]
}

@test "java pom: a template placeholder the script cannot substitute fails the render" {
  # The guard against the template and the substitution list drifting apart: a
  # pin added to the template without a matching `-e s|@…@|` would otherwise ship
  # a pom whose <version> is the literal '@NEW_TOOLCHAIN_PIN@', which maven only
  # rejects much later, with an opaque message.
  stage_java
  add_unknown_template_placeholder
  PROJ="$SANDBOX/proj"

  run_entry_point_split "$PROJ" com.acme acme-stubs 7.8.9
  [ "$status" -ne 0 ]
  grep -Fq "ERROR: the generated '$PROJ/pom.xml' still contains unsubstituted placeholders:" \
    "$SANDBOX/stderr.txt"
  # the offending field is named WITH its line number (grep -n), so the template
  # line that grew is findable
  grep -Eq '^[0-9][0-9]*:.*@NEW_TOOLCHAIN_PIN@' "$SANDBOX/stderr.txt"
  # everything the script DOES know about was substituted, so the failure is
  # precisely about the unknown field and not a blanket refusal
  grep -Fq "<artifactId>acme-stubs</artifactId>" "$PROJ/pom.xml"
  grep -Fq "<grpc.version>1.84.0-testpin</grpc.version>" "$PROJ/pom.xml"
  # and the "generated ..." success line is never printed
  run grep -Fq "Generated $PROJ/pom.xml" "$SANDBOX/stdout.txt"
  [ "$status" -ne 0 ]
}

@test "java pom: an unsubstituted placeholder aborts the pipeline, no pom is shipped" {
  stage_java
  add_unknown_template_placeholder
  run_orchestrator protos library
  [ "$status" -ne 0 ]
  grep -Fq "still contains unsubstituted placeholders" "$SANDBOX/stderr.txt"
  grep -Fq "@NEW_TOOLCHAIN_PIN@" "$SANDBOX/stderr.txt"
  grep -Fq "ERROR: make-lib-entry-point.sh failed" "$SANDBOX/stderr.txt"
  # the stubs came first, so protoc ran; maven never did
  [ -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$MVN_MOCK_LOG" ]
  # the half-rendered pom stays in the scratch project and never reaches the mount
  grep -Fq "@NEW_TOOLCHAIN_PIN@" "$MAVENPROJ/pom.xml"
  [ ! -f "$OUT/pom.xml" ]
  [ ! -d "$OUT/target" ]
}

@test "java pom: an existing pom.xml is kept and the offline caveat is spelled out" {
  stage_java
  PROJ="$SANDBOX/proj"; mkdir -p "$PROJ"
  printf '<project><artifactId>mine</artifactId></project>\n' > "$PROJ/pom.xml"
  run_entry_point "$PROJ" com.acme acme-stubs 7.8.9
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeping it instead of the default template"* ]]
  [[ "$output" == *"--offline"* ]]
  grep -Fq "<artifactId>mine</artifactId>" "$PROJ/pom.xml"
}

@test "java pom: the template's placeholders are exactly what the Dockerfile pins" {
  # The template, the substitution list and the image ENV are three files that
  # must agree; a placeholder added to the template without a matching ARG/ENV
  # renders an empty <version> that only maven notices, much later.
  tmpl="$REPO_ROOT/java/image-data/default-lib-files/pom.xml"
  checked=0
  for ph in $(grep -o '@[A-Z_][A-Z_]*@' "$tmpl" | tr -d '@' | sort -u); do
    case "$ph" in
      # supplied by the orchestrator's positional args, not by the image
      GROUP_ID|ARTIFACT_ID|VERSION) continue ;;
    esac
    # substituted by make-lib-entry-point.sh ...
    grep -Fq "s|@$ph@|" "$REPO_ROOT/java/image-data/make-lib-entry-point.sh"
    # ... from a value the Dockerfile declares as ARG and exports as ENV
    grep -Eq "^ARG $ph=" "$REPO_ROOT/java/Dockerfile"
    grep -Fq "$ph=\${$ph}" "$REPO_ROOT/java/Dockerfile"
    # ... and that make-lib-entry-point.sh refuses to render when it is empty
    grep -Fq "$ph" "$REPO_ROOT/java/image-data/make-lib-entry-point.sh"
    checked=$((checked + 1))
  done
  # never let a template rewrite turn this loop into a vacuous pass
  [ "$checked" -eq 5 ]
}

# --------------------------------- input-volume manifest / LICENSE merge rules

@test "java manifest: a pom.xml at the input-volume root wins over the template" {
  printf '<project>\n  <artifactId>client-supplied</artifactId>\n  <version>9.9.9</version>\n</project>\n' \
    > "$IN/pom.xml"
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  [[ "$output" == *"A pom.xml was specified in the mounted input volume"* ]]

  # carried through byte-identically ...
  cmp -s "$IN/pom.xml" "$OUT/pom.xml"
  # ... and it is what maven actually built, so the jar carries ITS coordinates
  [ -f "$OUT/target/client-supplied-9.9.9.jar" ]
}

@test "java manifest: the caller's LICENSE wins, otherwise the default is shipped" {
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  cmp -s "$REPO_ROOT/java/image-data/default-lib-files/LICENSE" "$OUT/LICENSE"

  rm -rf "$OUT" "$SANDBOX/image-data/src"; mkdir -p "$OUT"
  printf 'Proprietary - all rights reserved\n' > "$IN/LICENSE"
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  cmp -s "$IN/LICENSE" "$OUT/LICENSE"
}

@test "java manifest: overwriting an existing output pom.xml / LICENSE is announced" {
  printf '<project><artifactId>stale</artifactId></project>\n' > "$OUT/pom.xml"
  printf 'stale license\n' > "$OUT/LICENSE"
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: '$OUT/pom.xml' already exists"* ]]
  [[ "$output" == *"WARNING: '$OUT/LICENSE' already exists"* ]]
  # the warning is honest: they really were replaced
  run grep -Fq "stale" "$OUT/pom.xml"
  [ "$status" -ne 0 ]
}

# --------------------------------------- the offline maven build (stubs-2-lib)

@test "java maven: the package build is offline, batch-mode and repo-pinned" {
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]

  grep -Fq -- "--batch-mode" "$MVN_MOCK_LOG"
  grep -Fq -- "--offline" "$MVN_MOCK_LOG"
  grep -Fq -- "-f $MAVENPROJ/pom.xml" "$MVN_MOCK_LOG"
  grep -Fq -- "-Dmaven.repo.local=$SANDBOX/m2" "$MVN_MOCK_LOG"
  grep -Fq -- "-Dmaven.test.skip=true" "$MVN_MOCK_LOG"
  grep -Fq -- " package" "$MVN_MOCK_LOG"
  run grep -c '^mvn ' "$MVN_MOCK_LOG"
  [ "$output" = "1" ]
}

@test "java maven: MAVEN_REPO_LOCAL is derived from IMAGE_DATA_DIRECTORY when unset" {
  stage_java
  unset MAVEN_REPO_LOCAL
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  grep -Fq -- "-Dmaven.repo.local=$SANDBOX/image-data/.m2/repository" "$MVN_MOCK_LOG"
}

@test "java maven: no pom.xml at the project dir fails loudly and never calls mvn" {
  stage_java
  PROJ="$SANDBOX/proj"; mkdir -p "$PROJ"
  run bash "$SANDBOX/image-data/compile-stubs-2-lib.sh" "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no pom.xml at"* ]]
  [ ! -s "$MVN_MOCK_LOG" ]

  run bash "$SANDBOX/image-data/compile-stubs-2-lib.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no pom.xml at"* ]]
}

@test "java maven: a target/ without a jar in it is refused" {
  stage_java
  PROJ="$SANDBOX/proj"
  mkdir -p "$PROJ/src/main/java/com/ondewo/mock" "$PROJ/target/classes"
  printf '<project>\n  <artifactId>acme</artifactId>\n  <version>1.0.0</version>\n</project>\n' \
    > "$PROJ/pom.xml"
  printf 'class Test {}\n' > "$PROJ/src/main/java/com/ondewo/mock/Test.java"
  # mvn "succeeds" without packaging anything
  export MVN_FAIL_MATCH="package"
  export MVN_FAIL_RC=0

  run bash "$SANDBOX/image-data/compile-stubs-2-lib.sh" "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"produced no .jar"* ]]
}

@test "java maven: only the jars are staged, never the target/ scratch tree" {
  stage_java
  PROJ="$SANDBOX/proj"
  mkdir -p "$PROJ/src/main/java/com/ondewo/mock"
  printf '<project>\n  <artifactId>acme</artifactId>\n  <version>1.0.0</version>\n</project>\n' \
    > "$PROJ/pom.xml"
  printf 'class Test {}\n' > "$PROJ/src/main/java/com/ondewo/mock/Test.java"

  run bash "$SANDBOX/image-data/compile-stubs-2-lib.sh" "$PROJ"
  [ "$status" -eq 0 ]
  [ -f "$PROJ/lib/target/acme-1.0.0.jar" ]
  [ -f "$PROJ/lib/target/acme-1.0.0-sources.jar" ]
  [ ! -d "$PROJ/lib/target/classes" ]
  [ -f "$PROJ/lib/src/main/java/com/ondewo/mock/Test.java" ]
  [ -f "$PROJ/lib/pom.xml" ]
}

@test "java maven: the staged lib/ is rebuilt from scratch on every run" {
  stage_java
  PROJ="$SANDBOX/proj"
  mkdir -p "$PROJ/src/main/java/com/ondewo/mock" "$PROJ/lib/target"
  printf '<project>\n  <artifactId>acme</artifactId>\n  <version>1.0.0</version>\n</project>\n' \
    > "$PROJ/pom.xml"
  printf 'class Test {}\n' > "$PROJ/src/main/java/com/ondewo/mock/Test.java"
  printf 'stale\n' > "$PROJ/lib/target/acme-0.0.1.jar"

  run bash "$SANDBOX/image-data/compile-stubs-2-lib.sh" "$PROJ"
  [ "$status" -eq 0 ]
  [ ! -f "$PROJ/lib/target/acme-0.0.1.jar" ]
  [ -f "$PROJ/lib/target/acme-1.0.0.jar" ]
}

# ------------------------------------------------------------- stubs sub-script

@test "java stubs: missing arguments are refused with a usage message" {
  stage_java
  run bash "$SANDBOX/image-data/compile-proto-2-stubs.sh" "$SANDBOX/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-proto-2-stubs.sh"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "java stubs: a nonexistent -I import root is refused" {
  stage_java
  SRC="$SANDBOX/protos"; mkdir -p "$SRC"
  printf 'syntax = "proto3";\nmessage A {}\n' > "$SRC/a.proto"
  run bash "$SANDBOX/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/out" "$SANDBOX/no-such-root" "$SRC"
  [ "$status" -ne 0 ]
  [[ "$output" == *"protoc -I import root"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "java stubs: the target dir is created before protoc is called" {
  stage_java
  SRC="$SANDBOX/protos"; mkdir -p "$SRC"
  printf 'syntax = "proto3";\nmessage A {}\n' > "$SRC/a.proto"
  run bash "$SANDBOX/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/deep/nested/out" "$SRC" "$SRC"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/deep/nested/out" ]
  grep -Fq -- "--java_out=$SANDBOX/deep/nested/out " "$PROTOC_MOCK_LOG"
}

@test "java stubs: protoc exiting 0 without writing a .java file is caught, not reported as success" {
  stage_java
  stub_silent_protoc
  SRC="$SANDBOX/protos"; mkdir -p "$SRC"
  printf 'syntax = "proto3";\nmessage A {}\n' > "$SRC/a.proto"

  run_stubs "$SANDBOX/out" "$SRC" "$SRC"
  [ "$status" -ne 0 ]
  grep -Fq "ERROR: protoc produced no .java files in '$SANDBOX/out' - exiting" \
    "$SANDBOX/stderr.txt"
  # protoc really did run, on the real input set: this is the POST-condition
  # failing, not one of the pre-flight guards short-circuiting the run
  grep -Fq -- "$SRC/a.proto" "$PROTOC_MOCK_LOG"
  grep -Fq ".proto compilation finished." "$SANDBOX/stdout.txt"
  # ... so the ✅ banner is never reached and no file count is claimed
  run grep -Fq "Done .proto to grpc client stubs compilation" "$SANDBOX/stdout.txt"
  [ "$status" -ne 0 ]
  run grep -Fq "files generated by proto compilation" "$SANDBOX/stdout.txt"
  [ "$status" -ne 0 ]
}

@test "java stubs: an empty protoc output aborts the pipeline before maven, shipping nothing" {
  stage_java
  stub_silent_protoc
  run_orchestrator protos library
  [ "$status" -ne 0 ]
  grep -Fq "ERROR: protoc produced no .java files in '$STUBS' - exiting" "$SANDBOX/stderr.txt"
  grep -Fq "ERROR: compile-proto-2-stubs.sh failed" "$SANDBOX/stderr.txt"
  # protoc was reached, the package build never was ...
  [ -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$MVN_MOCK_LOG" ]
  # ... and the output volume is exactly as untouched as it was before the run
  [ ! -f "$OUT/pom.xml" ]
  [ ! -f "$OUT/LICENSE" ]
  [ ! -d "$OUT/src" ]
  [ ! -d "$OUT/target" ]
}

# ------------------------------- the image-build maven pre-warm (§9 no network)

# warm-maven-repo.sh runs at docker-build time only, but it is a java/ script and
# its whole contract - "generation needs no network" - is expressed in the goals
# and flags it hands maven, which the mock records exactly like any other call.

@test "java prewarm: packages the seed project online, then proves it offline" {
  stage_java
  export TMPDIR="$SANDBOX/tmpdir"; mkdir -p "$TMPDIR"
  run bash "$SANDBOX/image-data/warm-maven-repo.sh"
  [ "$status" -eq 0 ]

  # the seed proto is compiled, which smoke-tests protoc AND the grpc-java plugin
  grep -Fq -- "$SANDBOX/image-data/default-lib-files/seed.proto" "$PROTOC_MOCK_LOG"
  grep -Fq -- "--grpc-java_out=" "$PROTOC_MOCK_LOG"

  # exactly two maven runs: one ONLINE to fill the repository ...
  run grep -c '^mvn ' "$MVN_MOCK_LOG"
  [ "$output" = "2" ]
  run grep -c '^mvn --batch-mode --offline' "$MVN_MOCK_LOG"
  [ "$output" = "1" ]
  # ... and both against the same pinned local repository
  run grep -c -- "-Dmaven.repo.local=$SANDBOX/m2" "$MVN_MOCK_LOG"
  [ "$output" = "2" ]

  # the seed project is a temp dir and the EXIT trap removes it
  run bash -c 'find "$TMPDIR" -mindepth 1 | grep -c . || true'
  [ "$output" = "0" ]
}

@test "java prewarm: the warm-up goal list is a superset of the run-time one" {
  # `clean` is not part of the jar lifecycle, so a package-only warm-up never
  # downloads maven-clean-plugin and a later offline `clean` dies on a cache miss.
  stage_java
  export TMPDIR="$SANDBOX/tmpdir"; mkdir -p "$TMPDIR"
  run bash "$SANDBOX/image-data/warm-maven-repo.sh"
  [ "$status" -eq 0 ]
  run grep -c -- ' clean package$' "$MVN_MOCK_LOG"
  [ "$output" = "2" ]
  # what a generation run actually asks for, which must be covered by the above
  grep -Fq ' package' "$REPO_ROOT/java/image-data/compile-stubs-2-lib.sh"
}

@test "java prewarm: the remote-repository bookkeeping is dropped after the online pass" {
  stage_java
  export TMPDIR="$SANDBOX/tmpdir"; mkdir -p "$TMPDIR"
  mkdir -p "$SANDBOX/m2/com/acme"
  : > "$SANDBOX/m2/com/acme/_remote.repositories"
  : > "$SANDBOX/m2/com/acme/acme-1.0.0.pom.lastUpdated"
  : > "$SANDBOX/m2/com/acme/resolver-status.properties"
  : > "$SANDBOX/m2/com/acme/acme-1.0.0.jar"

  run bash "$SANDBOX/image-data/warm-maven-repo.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$SANDBOX/m2/com/acme/_remote.repositories" ]
  [ ! -f "$SANDBOX/m2/com/acme/acme-1.0.0.pom.lastUpdated" ]
  [ ! -f "$SANDBOX/m2/com/acme/resolver-status.properties" ]
  # the artifacts themselves stay
  [ -f "$SANDBOX/m2/com/acme/acme-1.0.0.jar" ]
}

@test "java prewarm: a failing offline verification fails the image build" {
  stage_java
  export TMPDIR="$SANDBOX/tmpdir"; mkdir -p "$TMPDIR"
  export MVN_FAIL_MATCH="--offline"
  run bash "$SANDBOX/image-data/warm-maven-repo.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"✅"* ]]
}

@test "java prewarm: a missing seed proto fails loudly before anything is downloaded" {
  stage_java
  rm -f "$SANDBOX/image-data/default-lib-files/seed.proto"
  run bash "$SANDBOX/image-data/warm-maven-repo.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"seed.proto"* ]]
  [ ! -s "$MVN_MOCK_LOG" ]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

# -------------------------------------------------- image / example plumbing

@test "java build.sh: a failing docker build propagates instead of printing the banner" {
  FAIL_BUILD_MATCH="ondewo-java-proto-compiler" run sh "$REPO_ROOT/java/build.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"✅"* ]]
}

@test "java build.sh: builds the contracted tag from its own directory" {
  run sh "$REPO_ROOT/java/build.sh"
  [ "$status" -eq 0 ]
  grep -Fq -- "build --no-cache -t ondewo-java-proto-compiler:latest $REPO_ROOT/java" "$DOCKER_MOCK_LOG"
}

@test "java image: the Dockerfile uses an exec-form ENTRYPOINT on the orchestrator" {
  run bash -c "grep -E '^ENTRYPOINT' '$REPO_ROOT/java/Dockerfile' | grep -vE '^ENTRYPOINT \['"
  [ -z "$output" ]
  grep -Fq 'ENTRYPOINT ["bash","compile-proto-2-java.sh"]' "$REPO_ROOT/java/Dockerfile"
}

@test "java example: run-compile.sh mounts its own directory and uses no -it for codegen" {
  mkdir -p "$SANDBOX/example"
  cp "$REPO_ROOT/java/example/run-compile.sh" "$SANDBOX/example/run.sh"
  run bash "$SANDBOX/example/run.sh"
  [ "$status" -eq 0 ]
  grep -Fq -- "-v $SANDBOX/example:/input-volume" "$DOCKER_MOCK_LOG"
  grep -Fq -- "-v $SANDBOX/example/lib:/output-volume" "$DOCKER_MOCK_LOG"
  grep -Fq -- "ondewo-java-proto-compiler protos" "$DOCKER_MOCK_LOG"
  [ -d "$SANDBOX/example/lib" ]
  # -it on a codegen run breaks every non-interactive caller
  run grep -Fq -- "run -it" "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
  # no doubled path from a mis-resolved script dir
  run grep -Fq -- "$SANDBOX/example$SANDBOX" "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "java example: the debug form keeps -it and overrides the entrypoint" {
  mkdir -p "$SANDBOX/example"
  cp "$REPO_ROOT/java/example/run-compile.sh" "$SANDBOX/example/run.sh"
  run bash "$SANDBOX/example/run.sh" debug
  [ "$status" -eq 0 ]
  grep -Fq -- "run -it --entrypoint /bin/bash" "$DOCKER_MOCK_LOG"
}

@test "java Makefile: the run target mounts via \$(pwd) and uses neither -it nor --user" {
  mkdir -p "$SANDBOX/mk"
  cp "$REPO_ROOT/java/Makefile" "$SANDBOX/mk/Makefile"
  # MAKEFLAGS= so a parent `make test` cannot leak its own flags/overrides in
  MAKEFLAGS= run make -C "$SANDBOX/mk" -n run
  [ "$status" -eq 0 ]
  [[ "$output" == *"-v $SANDBOX/mk/example/protos:/input-volume/protos"* ]]
  [[ "$output" == *"-v $SANDBOX/mk/example/lib:/output-volume"* ]]
  [[ "$output" != *"-it"* ]]
  [[ "$output" != *"--user"* ]]

  # TARGET_DIR is passed through as the orchestrator's arg 2
  MAKEFLAGS= run make -C "$SANDBOX/mk" -n run TARGET_DIR=ondewo
  [ "$status" -eq 0 ]
  [[ "$output" == *"ondewo-java-proto-compiler protos ondewo"* ]]
}

# ------------------------------------------------------------- known-bug cases

@test "java e2e: a 'java' directory in the input volume must not contaminate the library" {
  mkdir -p "$IN/java/target"
  printf 'not ours\n' > "$IN/java/target/some-client-app-9.9.9.jar"
  stage_java
  run bash ./compile-proto-2-java.sh protos library
  [ "$status" -eq 0 ]
  [ ! -f "$OUT/target/some-client-app-9.9.9.jar" ]
  [ -f "$OUT/target/ondewo-proto-stubs-java-0.0.0.jar" ]
}
