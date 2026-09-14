#!/usr/bin/env bats
# Cross-target consistency gate.
#
# The eleven language targets each ship their own copy of the same pipeline, and the
# per-target suites check each copy against its own history. What nothing checked was
# whether the copies still AGREE - and three properties had quietly drifted apart:
#
#   1. Symlinked protos. Every target used to match its inputs by name alone, so a
#      .proto a client symlinked into its protos directory was compiled. Adding
#      `-type f` to eight of them silently stopped that: `find <dir> -type f -iname
#      "*.proto"` returns 1 of 2 where `find -L <dir> -type f ...` returns 2 of 2,
#      because -type does not follow a link. angular/ and go/ avoided it by matching
#      on the name and then filtering with `[ -f ]`, which DOES follow the link; that
#      is the approach the other nine now use (written as find's own `-exec test -f`
#      where the list has to survive a path containing a newline). `find -L` is not
#      the fix: the flag has to precede the start path, which the BSD-portability gate
#      rejects, and -L makes find descend into symlinked directories, where a link
#      loop can hang the run.
#   2. `rm -rf` guards. Half the targets spell an interpolated deletion path
#      "${VAR:?}/x", so an unset variable aborts instead of widening the deletion;
#      the rest interpolated bare.
#   3. The generated-stub count. Every target computes one and prints it; angular,
#      csharp, go, js, nodejs, rust and typescript then ignored it, so "the generator
#      exited 0 and produced nothing" was a silent pass in exactly the targets that
#      have shipped longest - and js counted every *.js in the staged copy of the
#      input volume (webpack.js, the client's own sources) rather than its generated
#      output, which made the number meaningless as well as unchecked.
#
# Every case below LOOPS over the target list, and the list itself is checked against
# the targets discovered on disk, so a twelfth target cannot be added without
# satisfying all three. Everything runs against the PATH mocks - no Docker.

load 'helpers/setup'

setup() {
  common_setup
  # read as "unset vs set" by six targets' auto-detection; an ambient value would
  # steer every case here
  unset EXTRA_PROTO_DIRS
  # cpp `command -v`s its plugin, so it has to name the mock rather than the
  # container's absolute path; the other plugin paths are only ever passed to protoc
  # as a flag value
  export GRPC_CPP_PLUGIN=grpc_cpp_plugin
}
teardown() { common_teardown; }

# ---------------------------------------------------------------------------
# the target table
# ---------------------------------------------------------------------------

# The targets driven below. Checked against lang_targets() so the table cannot rot.
COVERED_TARGETS="angular cpp csharp go java js nodejs php python rust typescript"

# Every language target: a top-level directory shipping a build.sh and a Dockerfile.
# Discovered from the filesystem (not from git, whose PATH mock would answer with
# silence and turn the check vacuous).
lang_targets() {
  local d
  for d in "$REPO_ROOT"/*/; do
    d="${d%/}"
    if [ -f "$d/build.sh" ] && [ -f "$d/Dockerfile" ]; then echo "${d##*/}"; fi
  done | sort
}

# Every production shell script: the *.sh outside tests/.
prod_scripts() {
  find "$REPO_ROOT" -name '.git' -prune -o -path "$TESTS_DIR" -prune -o \
       -name '*.sh' -print | sort
}

# ---------------------------------------------------------------------------
# per-target sandbox + driver
# ---------------------------------------------------------------------------

# new_case <target>: a fresh proto root / output tree / mock log set, so the loops
# below cannot leak one target's state into the next.
new_case() {
  CASE="$SANDBOX/$1"
  rm -rf "${CASE:?}"
  ROOT="$CASE/protos"
  SRC="$ROOT/library"
  OUT="$CASE/out"
  mkdir -p "$SRC" "$OUT" "$CASE/vendor"
  PROTOC_MOCK_LOG="$CASE/protoc.log"
  PY_MOCK_LOG="$CASE/python.log"
  export PROTOC_MOCK_LOG PY_MOCK_LOG
  : > "$CASE/deps.txt"
  printf '[package]\nname = "stub"\nversion = "0.0.1"\n' > "$CASE/Cargo.toml.template"
}

write_proto() {
  printf 'syntax = "proto3";\npackage library;\nmessage %s { string x = 1; }\n' "$2" > "$1"
}

# A real proto plus a SYMLINKED one whose target sits outside the compiled tree, so
# the two are distinguishable in the mock's argv log.
seed_protos() {
  write_proto "$CASE/vendor/linked.proto" Linked
  write_proto "$SRC/alpha.proto" Alpha
  ln -s ../../vendor/linked.proto "$SRC/linked.proto"
}

# run_generator <target>: drive that target's generator over $ROOT / $SRC into $OUT.
# Ten targets share compile-proto-2-stubs.sh <stubs_target> <protos_root> <protos_src>
# and differ only in a fourth argument; python is a make target.
run_generator() {
  case "$1" in
    python)
      run make -C "$REPO_ROOT/python" -f Makefile generate_protos \
        INTERNAL_PROTO_DIR="$ROOT" INTERNAL_OUTPUT_DIR="$OUT" \
        INTERNAL_TARGET_PROTO_DIR=library
      ;;
    go)
      run bash "$REPO_ROOT/go/image-data/compile-proto-2-stubs.sh" \
        "$OUT" "$ROOT" "$SRC" "example.com/consistency"
      ;;
    nodejs|typescript)
      run bash "$REPO_ROOT/$1/image-data/compile-proto-2-stubs.sh" \
        "$OUT" "$ROOT" "$SRC" "$CASE/deps.txt"
      ;;
    rust)
      run bash "$REPO_ROOT/rust/image-data/compile-proto-2-stubs.sh" \
        "$OUT" "$ROOT" "$SRC" "$CASE/Cargo.toml.template"
      ;;
    *)
      run bash "$REPO_ROOT/$1/image-data/compile-proto-2-stubs.sh" "$OUT" "$ROOT" "$SRC"
      ;;
  esac
}

# Where the generator this target drives records its argv.
generator_log() {
  case "$1" in
    python) printf '%s' "$PY_MOCK_LOG" ;;
    *)      printf '%s' "$PROTOC_MOCK_LOG" ;;
  esac
}

# ---------------------------------------------------------------------------
# coverage: the table must name every target on disk
# ---------------------------------------------------------------------------

@test "consistency: the driver table covers exactly the targets that exist on disk" {
  local found expected
  found=$(lang_targets | tr '\n' ' ')
  expected=$(printf '%s\n' $COVERED_TARGETS | sort | tr '\n' ' ')
  echo "on disk : $found"
  echo "covered : $expected"
  [ "$found" = "$expected" ]
  # eleven, not "whatever happened to be there"
  [ "$(lang_targets | grep -c . || true)" -eq 11 ]
}

@test "consistency: every target in the table is really driven by run_generator" {
  # a target whose entry point moved would otherwise make its loop iteration a
  # vacuous pass: run_generator's fallback branch would fail to find the script and
  # the assertions would run against an empty log
  local t
  for t in $COVERED_TARGETS; do
    if [ "$t" = python ]; then
      [ -f "$REPO_ROOT/python/Makefile" ] || { echo "[$t] no Makefile"; return 1; }
    else
      [ -f "$REPO_ROOT/$t/image-data/compile-proto-2-stubs.sh" ] \
        || { echo "[$t] no image-data/compile-proto-2-stubs.sh"; return 1; }
    fi
  done
}

# ---------------------------------------------------------------------------
# property 1: symlinked protos are compiled, decoy directories are not
# ---------------------------------------------------------------------------

@test "consistency 1/3: every target compiles a SYMLINKED .proto" {
  # measured before the fix: `find <dir> -type f -iname "*.proto"` finds 1 of the 2
  # protos below, `find -L <dir> -type f -iname "*.proto"` finds 2 of 2
  local t log
  for t in $COVERED_TARGETS; do
    new_case "$t"
    seed_protos
    run_generator "$t"
    [ "$status" -eq 0 ] || { echo "[$t] exited $status"; echo "$output"; return 1; }
    log=$(generator_log "$t")
    grep -Fq "alpha.proto" "$log" \
      || { echo "[$t] the plain proto never reached the generator"; cat "$log"; return 1; }
    grep -Fq "linked.proto" "$log" \
      || { echo "[$t] the SYMLINKED proto was silently dropped"; cat "$log"; return 1; }
  done
}

@test "consistency 1/3: no target treats a DIRECTORY named *.proto as an input" {
  local t log
  for t in $COVERED_TARGETS; do
    new_case "$t"
    seed_protos
    mkdir -p "$SRC/decoy.proto"
    run_generator "$t"
    [ "$status" -eq 0 ] || { echo "[$t] exited $status"; echo "$output"; return 1; }
    log=$(generator_log "$t")
    grep -Fq "linked.proto" "$log" \
      || { echo "[$t] the SYMLINKED proto was dropped"; cat "$log"; return 1; }
    if grep -Fq "decoy.proto" "$log"; then
      echo "[$t] the decoy DIRECTORY was handed to the generator"; cat "$log"; return 1
    fi
  done
}

@test "consistency 1/3: a DIRECTORY named *.proto alone never satisfies the no-protos guard" {
  # the decoy must not be able to stand in for a real proto either
  local t
  for t in $COVERED_TARGETS; do
    new_case "$t"
    mkdir -p "$SRC/decoy.proto"
    run_generator "$t"
    [ "$status" -ne 0 ] \
      || { echo "[$t] a lone decoy directory was accepted as a proto set"; echo "$output"; return 1; }
  done
}

@test "consistency 1/3: a .proto symlink that resolves to nothing is a named error everywhere" {
  # the flip side of following the link: a link that leaves the mounted volume
  # dangles in the 'cp -r' copy, and a silently missing proto is a silently missing
  # service in the client
  local t
  for t in $COVERED_TARGETS; do
    new_case "$t"
    write_proto "$SRC/alpha.proto" Alpha
    ln -s /nowhere/gone.proto "$SRC/gone.proto"
    run_generator "$t"
    [ "$status" -ne 0 ] \
      || { echo "[$t] a dangling .proto symlink was accepted"; echo "$output"; return 1; }
    [[ "$output" == *"resolve to a file"* ]] \
      || { echo "[$t] aborted without naming the dangling link"; echo "$output"; return 1; }
  done
}

@test "consistency 1/3: a SYMLINK LOOP terminates with the same named error, it does not hang" {
  # why the fix is a name match plus a `test -f`, and never `find -L`: plain find
  # never descends a symlink, so a loop is just a link whose target is unreadable
  local t
  for t in $COVERED_TARGETS; do
    new_case "$t"
    write_proto "$SRC/alpha.proto" Alpha
    ln -s loop.proto "$SRC/loop.proto"
    run_generator "$t"
    [ "$status" -ne 0 ] \
      || { echo "[$t] a self-referential .proto symlink was accepted"; echo "$output"; return 1; }
    [[ "$output" == *"resolve to a file"* ]] \
      || { echo "[$t] aborted without naming the looping link"; echo "$output"; return 1; }
  done
}

@test "consistency 1/3: the node orchestrators scan a symlinked proto's google imports too" {
  # nodejs/ and typescript/ build proto-deps.txt from a separate scan over the same
  # directory. With `-type f` there, a symlinked proto was skipped and every google/
  # import it declares vanished from the list - so the dependency stubs were never
  # generated and the shipped library imported modules that do not exist.
  local t in_vol image_data
  for t in nodejs typescript; do
    new_case "$t"
    in_vol="$CASE/input"
    image_data="$CASE/image-data"
    mkdir -p "$in_vol/protos/library" "$in_vol/vendor" "$CASE/outvol"
    printf 'syntax = "proto3";\npackage library;\nimport "google/protobuf/empty.proto";\nmessage L { string x = 1; }\n' \
      > "$in_vol/vendor/linked.proto"
    ln -s ../../vendor/linked.proto "$in_vol/protos/library/linked.proto"
    # a plain proto beside it, so the stub step succeeds either way and the
    # assertion below is about the import SCAN alone
    write_proto "$in_vol/protos/library/alpha.proto" Alpha
    printf '{"name":"fixture","version":"0.0.1"}\n' > "$in_vol/package.json"
    # the orchestrator calls its siblings as ./x.sh and stages into
    # $IMAGE_DATA_DIRECTORY, so it runs from a copy of the target's image-data
    cp -r "$REPO_ROOT/$t/image-data" "$image_data"

    export IMAGE_DATA_DIRECTORY="$image_data" INPUT_VOLUME_FS="$in_vol" \
           OUTPUT_VOLUME_FS="$CASE/outvol" NPM_MOCK_LOG="$CASE/npm.log"
    run bash -c "cd '$image_data' && bash ./compile-proto-2-$t.sh protos library"
    unset IMAGE_DATA_DIRECTORY INPUT_VOLUME_FS OUTPUT_VOLUME_FS NPM_MOCK_LOG
    echo "[$t] status=$status"
    echo "$output"
    [ "$status" -eq 0 ] || { echo "[$t] orchestrator failed"; return 1; }
    grep -Fxq "google/protobuf/empty.proto" "$image_data/src/proto-deps.txt" \
      || { echo "[$t] the symlinked proto's google import never reached proto-deps.txt"; return 1; }
  done
}

@test "consistency 1/3: the java orchestrator rewrites a symlinked proto's java_package too" {
  # java's second pass over the protos strips the inherited
  # com.google.cloud.dialogflow.v2 java_package off the temp copy. Skipped for a
  # symlinked proto, that proto is compiled anyway - into Google's namespace, which
  # is the split-package breakage the rewrite exists to prevent.
  new_case java
  local in_vol="$CASE/input" image_data="$CASE/image-data"
  mkdir -p "$in_vol/protos/library" "$in_vol/google/dialogflow" "$CASE/outvol"
  # the real shape: the forked proto lives in the vendored google/ checkout, which the
  # rewrite deliberately skips, and the client symlinks it into its own tree - where it
  # IS compiled, and therefore has to be rewritten through the link
  printf 'syntax = "proto3";\npackage library;\noption java_package = "com.google.cloud.dialogflow.v2";\nmessage L { string x = 1; }\n' \
    > "$in_vol/google/dialogflow/session.proto"
  ln -s ../../google/dialogflow/session.proto "$in_vol/protos/library/linked.proto"
  write_proto "$in_vol/protos/library/alpha.proto" Alpha
  cp -r "$REPO_ROOT/java/image-data" "$image_data"

  # the pom template's version pins normally come from the Dockerfile ARGs
  export GRPC_JAVA_VERSION="1.84.0-testpin" PROTOBUF_JAVA_VERSION="4.33.6-testpin" \
         GOOGLE_COMMON_PROTOS_VERSION="2.76.0-testpin" \
         MAVEN_SOURCE_PLUGIN_VERSION="3.4.0-testpin" JAVA_RELEASE="17"
  export IMAGE_DATA_DIRECTORY="$image_data" INPUT_VOLUME_FS="$in_vol" \
         OUTPUT_VOLUME_FS="$CASE/outvol" MAVEN_REPO_LOCAL="$CASE/m2" \
         MVN_MOCK_LOG="$CASE/mvn.log"
  run bash -c "cd '$image_data' && bash ./compile-proto-2-java.sh protos library"
  unset IMAGE_DATA_DIRECTORY INPUT_VOLUME_FS OUTPUT_VOLUME_FS MAVEN_REPO_LOCAL MVN_MOCK_LOG \
        GRPC_JAVA_VERSION PROTOBUF_JAVA_VERSION GOOGLE_COMMON_PROTOS_VERSION \
        MAVEN_SOURCE_PLUGIN_VERSION JAVA_RELEASE
  echo "$output"
  [ "$status" -eq 0 ]
  grep -Fq 'option java_package = "com.ondewo.nlu";' "$image_data/src/protos/library/linked.proto"
  run grep -Fq 'com.google.cloud.dialogflow.v2' "$image_data/src/protos/library/linked.proto"
  [ "$status" -ne 0 ]
  # ... and the vendored google/ copy it came from is still left alone
  grep -Fq 'com.google.cloud.dialogflow.v2' "$image_data/src/google/dialogflow/session.proto"
  # sed -i.bak renames the ORIGINAL aside, so a symlinked proto's backup is itself a
  # symlink; the cleanup sweep has to take those too
  [ "$(find "$image_data/src" -name "*.proto.bak" | grep -c . || true)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# property 2: every rm -rf that interpolates a variable is ${VAR:?}-guarded
# ---------------------------------------------------------------------------

# scan_rm_rf <file>... : echo "file:line:text" for every non-comment `rm -r*` line on
# which an ARGUMENT starts with an unguarded expansion. An argument that starts with
# "${VAR:?}" is safe whatever follows it ("${OUT:?}/$stale" cannot widen past $OUT),
# so guarded expansions are blanked out before the check.
scan_rm_rf() {
  local f
  for f in "$@"; do
    grep -nE 'rm[[:space:]]+-[a-zA-Z]*[rR]' "$f" 2>/dev/null \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
      | while IFS= read -r line; do
          args=$(printf '%s\n' "$line" | sed 's|^.*rm[[:space:]][[:space:]]*-[a-zA-Z]*[[:space:]][[:space:]]*||')
          args=$(printf '%s\n' "$args" | sed 's|\${[A-Za-z_][A-Za-z0-9_]*:?}|GUARDED|g')
          if printf '%s\n' "$args" | grep -qE '(^|[[:space:]]|["'"'"'])\$'; then
            printf '%s:%s\n' "$f" "$line"
          fi
        done
  done
}

@test "consistency 2/3: no production script has an unguarded 'rm -rf \$VAR'" {
  run scan_rm_rf $(prod_scripts)
  echo "$output"
  [ -z "$output" ]
}

@test "consistency 2/3: every target's own scripts are in that scan, and it is not vacuous" {
  local scripts count t
  scripts=$(prod_scripts)
  count=$(printf '%s\n' "$scripts" | grep -c . || true)
  echo "scanned $count production scripts"
  [ "$count" -ge 50 ]
  for t in $COVERED_TARGETS; do
    printf '%s\n' "$scripts" | grep -Fq "/$t/build.sh" \
      || { echo "[$t] build.sh missing from the scan"; return 1; }
  done
  # the scan really is looking at rm -rf lines: the repo has plenty, and they are all
  # guarded, so the scanner must find them and clear them rather than see nothing
  local guarded
  guarded=$(printf '%s\n' "$scripts" | while IFS= read -r f; do
              grep -hE 'rm[[:space:]]+-[a-zA-Z]*[rR].*\$' "$f" 2>/dev/null \
                | grep -vE '^[[:space:]]*#' || true
            done | grep -c . || true)
  echo "rm -r* lines interpolating a variable: $guarded"
  [ "$guarded" -ge 15 ]
}

@test "consistency 2/3: scan_rm_rf really flags an unguarded deletion" {
  # a self-test of the scanner, so the clean result above cannot be a broken regex
  local probe="$SANDBOX/probe.sh"
  printf '#!/bin/sh\nrm -rf "$LIB_DIR"\n' > "$probe"
  run scan_rm_rf "$probe"
  echo "$output"
  [ -n "$output" ]

  printf '#!/bin/sh\nrm -rf "${LIB_DIR:?}"\nrm -rf "${OUT:?}/$stale"\nrm -rf /tmp/fixed\n' > "$probe"
  run scan_rm_rf "$probe"
  echo "$output"
  [ -z "$output" ]

  # ${VAR} and ${VAR:-default} are NOT guards
  printf '#!/bin/sh\nrm -rf "${LIB_DIR}"\n' > "$probe"
  run scan_rm_rf "$probe"
  [ -n "$output" ]
  printf '#!/bin/sh\nrm -rf "${LIB_DIR:-/}"\n' > "$probe"
  run scan_rm_rf "$probe"
  [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# property 3: a zero generated-stub count is an error everywhere
# ---------------------------------------------------------------------------

@test "consistency 3/3: a generator that exits 0 having written nothing fails every target" {
  local t
  for t in $COVERED_TARGETS; do
    new_case "$t"
    seed_protos
    export PROTOC_MOCK_NO_STUBS=1 PY_MOCK_NO_STUBS=1
    run_generator "$t"
    unset PROTOC_MOCK_NO_STUBS PY_MOCK_NO_STUBS
    [ "$status" -ne 0 ] \
      || { echo "[$t] an empty generator run was a silent pass"; echo "$output"; return 1; }
    [[ "$output" == *"produced no"* ]] \
      || { echo "[$t] aborted without saying the generator produced nothing"; echo "$output"; return 1; }
  done
}

@test "consistency 3/3: the same targets succeed and report a non-zero count when output IS written" {
  # the guard above must not be satisfiable by a target that simply always fails
  local t
  for t in $COVERED_TARGETS; do
    new_case "$t"
    seed_protos
    run_generator "$t"
    [ "$status" -eq 0 ] || { echo "[$t] exited $status"; echo "$output"; return 1; }
    [[ "$output" == *"files generated by proto compilation: "* ]] \
      || { echo "[$t] never reported a generated-stub count"; echo "$output"; return 1; }
    [[ "$output" != *"files generated by proto compilation: 0"* ]] \
      || { echo "[$t] reported a zero count and carried on"; echo "$output"; return 1; }
  done
}

@test "consistency 3/3: js counts its GENERATED stubs, not the staged input volume" {
  # js has no separable api/ subtree: compile-proto-2-js.sh passes the whole copy of
  # the mounted input volume as the stubs target dir, so an unfiltered *.js tally
  # counts webpack.js, webpack.dev.js and every source the client mounted - and
  # reports a comfortable non-zero number for a run that generated nothing at all.
  new_case js
  seed_protos
  # three files a real staged input volume always carries, none of them generated
  printf 'module.exports={};\n' > "$OUT/webpack.js"
  printf 'module.exports={};\n' > "$OUT/webpack.common.js"
  printf 'module.exports={};\n' > "$OUT/webpack.dev.js"

  export PROTOC_MOCK_NO_STUBS=1
  run_generator js
  unset PROTOC_MOCK_NO_STUBS
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"produced no"* ]]
  # ... and the three staged files are still there: they were never generated output
  [ -f "$OUT/webpack.js" ]
}
