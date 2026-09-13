#!/usr/bin/env bats
# Full coverage of the `php` proto-compiler target, driven on the HOST.
#
# The real scripts under php/image-data/ are executed; only the container paths
# are redirected (IMAGE_DATA_DIRECTORY / INPUT_VOLUME_FS / OUTPUT_VOLUME_FS /
# TEMP_SRC_DIRECTORY) and the toolchain is PATH-mocked (protoc materialises PHP
# stubs per *_out flag, composer writes composer.lock + vendor/, php models the
# "do the stubs load?" heredoc). No Docker, no network, no real toolchain.
#
# What the php target has to get right, and what is asserted here:
#   * the mounted input volume is copied to $TEMP_SRC_DIRECTORY and NEVER mutated
#   * the stubs are staged in generated-src/, so a client's own PSR-4 src/ in the
#     input volume can never be merged into the compiler-owned generated tree
#   * src/ and vendor/ in the output volume are compiler-owned and wiped per run;
#     composer.json/composer.lock are overwritten; hand-written auth/ is not
#   * google/protobuf/** is never regenerated (duplicate class declarations fatal
#     at autoload), while imported non-well-known google protos still are
#   * the package build really runs composer, offline, in the staged lib/
#   * every sub-script failure aborts the entrypoint with a named error
#
# jq is a hard runtime dependency of this target (manifest merge + auth/ classmap
# registration), so the manifest assertions below use it too.

load 'helpers/setup'

setup() {
  common_setup
  export PROTOC_MOCK_LOG="$SANDBOX/protoc.log"
  export COMPOSER_MOCK_LOG="$SANDBOX/composer.log"
  export PHP_MOCK_LOG="$SANDBOX/php.log"
  export PHP_MOCK_STDIN_LOG="$SANDBOX/php-stdin.log"

  IN="$SANDBOX/input"
  OUT="$SANDBOX/output"
  # the default TEMP_SRC_DIRECTORY the orchestrator derives ($IMAGE_DATA/src)
  TEMP="$SANDBOX/image-data/src"
  mkdir -p "$IN" "$OUT"
}
teardown() { common_teardown; }

# ------------------------------------------------------------------ helpers

# write_proto <abs-path> <package> [<import> ...]
# A proto with one message and one service, so the grpc plugin has something to
# emit and the import edge is real.
write_proto() {
  local path=$1 pkg=$2 imp
  shift 2
  mkdir -p "$(dirname "$path")"
  {
    printf 'syntax = "proto3";\npackage %s;\n' "$pkg"
    for imp in "$@"; do printf 'import "%s";\n' "$imp"; done
    printf 'message M { string name = 1; }\nservice S { rpc Call (M) returns (M); }\n'
  } > "$path"
}

# The default two-proto input tree: protos/test.proto imports
# protos/dependency/myimport.proto.
seed_default_protos() {
  write_proto "$IN/protos/dependency/myimport.proto" dependency
  write_proto "$IN/protos/test.proto" example "dependency/myimport.proto"
}

# Copy php/image-data into the sandbox and point the container-path knobs at it.
# The orchestrator invokes its siblings as ./x.sh, so the CWD has to be the
# staged image-data directory - exactly like the image's WORKDIR.
stage_php() {
  cp -r "$REPO_ROOT/php/image-data" "$SANDBOX/image-data"
  cd "$SANDBOX/image-data"
  export IMAGE_DATA_DIRECTORY="$SANDBOX/image-data"
  export INPUT_VOLUME_FS="$IN"
  export OUTPUT_VOLUME_FS="$OUT"
}

# A portable layout+content fingerprint of a directory tree (no `find -printf`,
# no GNU-only checksum flags). Used to prove the input volume is untouched.
snapshot_tree() {
  local f
  (
    cd "$1" || exit 1
    find . -print | sort
    find . -type f -print | sort | while IFS= read -r f; do
      printf '== %s\n' "$f"
      cat "$f"
    done
  )
}

# grep -c aborts a bats test when the count is zero; this never does.
count_matches() {
  grep -c -- "$1" "$2" 2>/dev/null || true
}

# A composer shim ahead of the mock on PATH that records the working directory
# and COMPOSER_DISABLE_NETWORK of every call before delegating. Both are
# load-bearing and invisible in an argv log: the package build must run inside
# the staged lib/, and every composer call must be pinned offline so a cache
# miss fails instead of silently reaching packagist.
install_composer_env_probe() {
  mkdir -p "$SANDBOX/shim"
  # *_MOCK_LOG is exempt from common_setup's toolchain-env scrub, so the name
  # cannot be eaten by a future re-scrub.
  COMPOSER_ENV_MOCK_LOG="$SANDBOX/composer-env.log"
  cat > "$SANDBOX/shim/composer" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$PWD" "\${COMPOSER_DISABLE_NETWORK-UNSET}" "\$*" >> "$COMPOSER_ENV_MOCK_LOG"
exec "$MOCK_BIN/composer" "\$@"
EOF
  chmod +x "$SANDBOX/shim/composer"
  PATH="$SANDBOX/shim:$PATH"
  export PATH COMPOSER_ENV_MOCK_LOG
}

# =====================================================================
# Orchestrator, end to end
# =====================================================================

@test "php e2e: the full pipeline stages composer.json, composer.lock, src/ and vendor/ into the output volume" {
  seed_default_protos
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  # the published package layout
  [ -f "$OUT/composer.json" ]
  [ -f "$OUT/composer.lock" ]
  [ -f "$OUT/src/GPBMetadata/Mock/Test.php" ]   # descriptor bootstrap
  [ -f "$OUT/src/Mock/TestMessage.php" ]        # message class
  [ -f "$OUT/src/Mock/TestServiceClient.php" ]  # grpc_php_plugin service stub
  [ -f "$OUT/vendor/autoload.php" ]
  [ -f "$OUT/vendor/composer/autoload_classmap.php" ]

  # the well-known types ship inside the google/protobuf composer package;
  # regenerating them fatals at autoload, so this must never exist
  [ ! -d "$OUT/src/Google" ]

  [[ "$output" == *"compilation finished successfully"* ]]
}

@test "php e2e: the mounted input volume is never mutated" {
  seed_default_protos
  printf '{"name":"client/php","require":{}}\n' > "$IN/composer.json"
  stage_php

  before="$(snapshot_tree "$IN")"
  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  after="$(snapshot_tree "$IN")"

  [ "$before" = "$after" ]
  # in particular, no stub, no lib/ and no vendor/ leak back into the mount
  [ ! -e "$IN/lib" ]
  [ ! -e "$IN/vendor" ]
  [ ! -e "$IN/generated-src" ]
}

@test "php e2e: compilation happens in the temp src dir, which is env-overridable" {
  seed_default_protos
  stage_php
  export TEMP_SRC_DIRECTORY="$SANDBOX/elsewhere"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  # the input volume was copied there, stubs staged beside it, package built there
  [ -f "$SANDBOX/elsewhere/protos/test.proto" ]
  [ -d "$SANDBOX/elsewhere/generated-src" ]
  [ -f "$SANDBOX/elsewhere/lib/composer.json" ]
  # and the default location was NOT used
  [ ! -e "$TEMP" ]
  run grep -Fq -- "--php_out=$SANDBOX/elsewhere/generated-src" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "php e2e: a client's hand-written src/ in the input volume is not merged into the generated stubs" {
  # Regression: the stubs are staged in generated-src/, not src/. The whole input
  # volume is copied into $TEMP_SRC_DIRECTORY, and src/ is THE conventional PHP
  # source directory - staging into src/ would ship a client's own classes as
  # generated output (and get them wiped on the next run).
  seed_default_protos
  mkdir -p "$IN/src"
  printf '<?php\nclass HandWritten {}\n' > "$IN/src/HandWritten.php"
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  # copied into the scratch tree (it is part of the input volume) ...
  [ -f "$TEMP/src/HandWritten.php" ]
  # ... but never into the generated stubs or the shipped package
  [ ! -e "$TEMP/generated-src/HandWritten.php" ]
  [ ! -e "$OUT/src/HandWritten.php" ]
  [ -f "$OUT/src/Mock/TestMessage.php" ]
}

@test "php e2e: a client's own generated-src/ in the input volume is not merged into the stubs" {
  # generated-src/ is compiler-owned, but it is created INSIDE the tree the whole
  # input volume was just copied into - so whatever a client keeps under that name
  # (its own checked-in generation output, or the previous run's when the output
  # volume is nested in the input volume) was picked up by the stub staging and
  # shipped as this run's generated output.
  seed_default_protos
  mkdir -p "$IN/generated-src/Client"
  printf '<?php\nclass ClientOwned {}\n' > "$IN/generated-src/ClientOwned.php"
  printf '<?php\nclass Nested {}\n' > "$IN/generated-src/Client/Nested.php"
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  # wiped before protoc writes, so it reaches neither the stub tree ...
  [ ! -e "$TEMP/generated-src/ClientOwned.php" ]
  [ ! -e "$TEMP/generated-src/Client" ]
  # ... nor the shipped package
  [ ! -e "$OUT/src/ClientOwned.php" ]
  [ ! -e "$OUT/src/Client" ]
  # while the real stubs are still there
  [ -f "$OUT/src/Mock/TestMessage.php" ]
  [ -f "$OUT/src/Mock/TestServiceClient.php" ]
}

@test "php e2e: composer runs validate -> update -> dump-autoload, offline, inside the staged lib/" {
  seed_default_protos
  stage_php
  install_composer_env_probe

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  [ "$(count_matches '^composer ' "$COMPOSER_MOCK_LOG")" -eq 3 ]
  [[ "$(sed -n '1p' "$COMPOSER_MOCK_LOG")" == "composer validate "* ]]
  [[ "$(sed -n '2p' "$COMPOSER_MOCK_LOG")" == "composer update "* ]]
  [[ "$(sed -n '3p' "$COMPOSER_MOCK_LOG")" == "composer dump-autoload "* ]]

  # `update`, not `install`: the image's lock is keyed to the prewarm manifest
  run grep -Fq -- "composer install" "$COMPOSER_MOCK_LOG"
  [ "$status" -ne 0 ]
  # offline resolution + the consumer-only ext-grpc requirement waived
  run grep -Fq -- "--prefer-dist" "$COMPOSER_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "--ignore-platform-req=ext-grpc" "$COMPOSER_MOCK_LOG"
  [ "$status" -eq 0 ]
  # --optimize is what turns the generated tree into an authoritative class map
  run grep -Fq -- "dump-autoload --optimize" "$COMPOSER_MOCK_LOG"
  [ "$status" -eq 0 ]

  # every call is pinned offline and made from the staged package directory
  [ "$(count_matches '|' "$COMPOSER_ENV_MOCK_LOG")" -eq 3 ]
  while IFS='|' read -r cwd offline _; do
    [ "$offline" = "1" ]
    [ "$cwd" = "$TEMP/lib" ]
  done < "$COMPOSER_ENV_MOCK_LOG"
}

@test "php e2e: the generated stubs are load-verified by php before the package ships" {
  seed_default_protos
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  # the verification is the argument-less heredoc form
  [ "$(count_matches '^php $' "$PHP_MOCK_LOG")" -eq 1 ]
  # and it really walks the generated descriptors
  run grep -Fq 'vendor/composer/autoload_classmap.php' "$PHP_MOCK_STDIN_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq 'initOnce()' "$PHP_MOCK_STDIN_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq 'GPBMetadata' "$PHP_MOCK_STDIN_LOG"
  [ "$status" -eq 0 ]
}

@test "php e2e: a second run is idempotent - same layout, no duplicated output" {
  seed_default_protos
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  first="$(snapshot_tree "$OUT")"

  rm -rf "$TEMP"
  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  second="$(snapshot_tree "$OUT")"

  [ "$first" = "$second" ]
}

# =====================================================================
# Output-volume fallback
# =====================================================================

@test "php fallback: a missing output volume falls back to <input volume>/lib" {
  seed_default_protos
  stage_php
  rm -rf "$OUT"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  [[ "$output" == *"creating output in sourcevolume/lib directory"* ]]

  [ -f "$IN/lib/composer.json" ]
  [ -f "$IN/lib/composer.lock" ]
  [ -f "$IN/lib/src/Mock/TestMessage.php" ]
  [ -f "$IN/lib/vendor/autoload.php" ]
  # the real output volume path was not resurrected
  [ ! -e "$OUT" ]
}

# =====================================================================
# Stale-output cleanup (compiler-owned vs. client-owned paths)
# =====================================================================

@test "php cleanup: a stub left over from a previous run does not survive" {
  seed_default_protos
  stage_php
  # a stub for a proto that has since been deleted/renamed
  mkdir -p "$OUT/src/Ondewo/Gone"
  printf '<?php\nclass Orphan {}\n' > "$OUT/src/Ondewo/Gone/Orphan.php"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  [ ! -e "$OUT/src/Ondewo/Gone/Orphan.php" ]
  [ ! -e "$OUT/src/Ondewo" ]
  [ -f "$OUT/src/Mock/TestMessage.php" ]
}

@test "php cleanup: a stale vendor tree is replaced, not merged into" {
  seed_default_protos
  stage_php
  mkdir -p "$OUT/vendor/dropped-dependency"
  printf '<?php\n' > "$OUT/vendor/dropped-dependency/Old.php"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  [ ! -e "$OUT/vendor/dropped-dependency" ]
  [ -f "$OUT/vendor/autoload.php" ]
}

@test "php cleanup: with the output volume nested in the input volume, the previous package does not leak into the next one" {
  # The SHIPPED example mounts input=$FILEDIRECTORY and output=$FILEDIRECTORY/lib,
  # so lib/ is INSIDE the input volume: from the second run on, the previous run's
  # output is part of the copied-in tree and lands in $TEMP_SRC_DIRECTORY/lib -
  # which is the package STAGING directory. Cleaning only lib/src there left the
  # rest of it to be packaged and copied straight back out.
  seed_default_protos
  stage_php
  export OUTPUT_VOLUME_FS="$IN/lib"
  mkdir -p "$IN/lib"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  [ -f "$IN/lib/src/Mock/TestMessage.php" ]

  # things the first run shipped that the second one no longer produces
  mkdir -p "$IN/lib/vendor/dropped-dependency"
  printf '<?php\n' > "$IN/lib/vendor/dropped-dependency/Old.php"
  printf 'stale\n' > "$IN/lib/orphan-artifact.txt"

  rm -rf "$TEMP"
  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  # neither reached the staged package ...
  [ ! -e "$TEMP/lib/vendor/dropped-dependency" ]
  [ ! -e "$TEMP/lib/orphan-artifact.txt" ]
  # ... so the dropped dependency is not published a second time
  [ ! -e "$IN/lib/vendor/dropped-dependency" ]
  [ -f "$IN/lib/vendor/autoload.php" ]
  [ -f "$IN/lib/src/Mock/TestMessage.php" ]
}

@test "php cleanup: hand-written client files outside src/ and vendor/ survive" {
  seed_default_protos
  stage_php
  mkdir -p "$OUT/auth" "$OUT/tests"
  printf '<?php\nclass TokenProvider {}\n' > "$OUT/auth/TokenProvider.php"
  printf '<?php\n// client test\n' > "$OUT/tests/ClientTest.php"
  printf '# client readme\n' > "$OUT/README.md"
  auth_before="$(cat "$OUT/auth/TokenProvider.php")"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  [ "$(cat "$OUT/auth/TokenProvider.php")" = "$auth_before" ]
  [ -f "$OUT/tests/ClientTest.php" ]
  [ -f "$OUT/README.md" ]
}

# =====================================================================
# Argument handling
# =====================================================================

@test "php args: no argument defaults the protos root to <input volume>/protos" {
  seed_default_protos
  stage_php

  run bash ./compile-proto-2-php.sh
  [ "$status" -eq 0 ]
  run grep -Fq -- "-I $IN/protos " "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "php args: an explicit relative protos dir becomes protoc's -I root" {
  write_proto "$IN/ondewo-nlu-api/dependency/myimport.proto" dependency
  write_proto "$IN/ondewo-nlu-api/test.proto" example "dependency/myimport.proto"
  stage_php

  run bash ./compile-proto-2-php.sh ondewo-nlu-api
  [ "$status" -eq 0 ]
  run grep -Fq -- "-I $IN/ondewo-nlu-api " "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # paths handed to protoc are root-relative, never absolute
  run grep -Fq -- " test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- " $IN/ondewo-nlu-api/test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "php args: the target subdir scopes the entry set to one sub-tree" {
  write_proto "$IN/api/dependency/myimport.proto" dependency
  write_proto "$IN/api/ondewo/nlu/session.proto" ondewo.nlu "dependency/myimport.proto"
  write_proto "$IN/api/other/unrelated.proto" other
  stage_php

  run bash ./compile-proto-2-php.sh api ondewo
  [ "$status" -eq 0 ]

  # in the entry set ...
  run grep -Fq -- " ondewo/nlu/session.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # ... its transitive import is pulled in even though it lives outside the subdir
  run grep -Fq -- " dependency/myimport.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # ... and the sibling sub-tree is not compiled
  run grep -Fq -- "other/unrelated.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # -I still points at the protos ROOT, not at the scoped sub-directory
  run grep -Fq -- "-I $IN/api " "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "php args: a target subdir that does not exist fails loudly" {
  seed_default_protos
  stage_php

  run bash ./compile-proto-2-php.sh protos nosuchdir
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]
  [ ! -s "$COMPOSER_MOCK_LOG" ]
}

# =====================================================================
# The no-protos guard
# =====================================================================

@test "php guard: an empty protos dir fails and never starts the package build" {
  mkdir -p "$IN/protos"
  printf 'not a proto\n' > "$IN/protos/README.md"
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"No proto files were found"* ]]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]

  # neither composer nor the load verification may have run ...
  [ ! -s "$COMPOSER_MOCK_LOG" ]
  [ ! -s "$PHP_MOCK_LOG" ]
  # ... and nothing may have been published
  [ ! -e "$OUT/composer.json" ]
  [ ! -e "$OUT/src" ]
}

@test "php guard: a DIRECTORY named *.proto is not mistaken for a proto file" {
  # Regression: the entry-set find matched on the name alone, so a directory
  # called e.g. "vendor.proto" (a vendored checkout, an unpacked bundle) entered
  # the file set. The resolver then ran `cd`/`sed` on a garbage path, printed the
  # wrong file count, dropped a real proto from the list - and still exited 0,
  # because its failure is swallowed by the `if ! ALL_PROTO_FILES=$(...)` it runs
  # inside (set -e is disabled for an if-condition).
  seed_default_protos
  mkdir -p "$IN/protos/vendor.proto/nested"
  printf 'x\n' > "$IN/protos/vendor.proto/nested/keep.txt"
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  # the two REAL protos, not three
  [[ "$output" == *"Found 2 .proto files"* ]]
  # and no resolver flailing on the directory
  [[ "$output" != *"No such file or directory"* ]]
  [[ "$output" != *"can't read"* ]]

  run grep -Fq -- "vendor.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # the real entry protos both survived into the protoc call
  run grep -Fq -- " test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- " dependency/myimport.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "php guard: a dependency-resolution failure aborts instead of compiling a short file list" {
  # The other half of the bug above: the resolver runs inside a command
  # substitution in an if-condition, so nothing it does propagates by itself. Every
  # failure inside it has to abort the subshell explicitly, or the run continues
  # with a silently truncated proto list.
  write_proto "$SANDBOX/src/test.proto" example

  run bash "$REPO_ROOT/php/image-data/compile-proto-2-stubs.sh" \
    "$SANDBOX/out" "$SANDBOX/no-such-root" "$SANDBOX/src"
  [ "$status" -ne 0 ]

  [[ "$output" == *"failed to resolve"* ]]
  [[ "$output" == *"dependency resolution failed"* ]]
  # it must not have got as far as announcing (and compiling) a file list
  [[ "$output" != *"Consuming"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "php guard: a proto whose filename contains a newline aborts instead of compiling a mangled list" {
  # The third member of the same family as the two cases above: the entry set is a
  # NEWLINE-separated string, so a .proto whose NAME contains a newline arrives at
  # the resolver split into two fragments. Neither is a readable file - the first is
  # the name truncated at the newline, and the second is a bare tail that the
  # root-prefix fixup turns into '<root>/<tail>' - and neither can be handed to
  # `cd`/`sed`. The fragment also inflates the entry count, so without the explicit
  # guard the swallowed failure would publish a package built from a proto list that
  # is both short (the real file dropped) and wrong (two ghosts added).
  seed_default_protos
  newline_proto="$IN/protos/"$'weird\nmyimport.proto'
  write_proto "$newline_proto" weird

  stage_php
  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]

  # the fixup ran first (the reported path carries the protos root twice: the
  # root prefix glued in front of an already absolute fragment) ...
  [[ "$output" == *"'$IN/protos/$IN/protos/weird' is not a readable .proto file"* ]]
  # ... and the failure really propagated out of the command substitution
  [[ "$output" == *"dependency resolution failed"* ]]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]

  # it never got as far as announcing, let alone compiling, a file list
  [[ "$output" != *"Consuming"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$COMPOSER_MOCK_LOG" ]
  [ ! -s "$PHP_MOCK_LOG" ]
  # ... and nothing was published
  [ ! -e "$OUT/composer.json" ]
  [ ! -e "$OUT/src" ]
  [ ! -e "$OUT/vendor" ]
}

@test "php guard: a DIRECTORY named *.php does not satisfy the generated-stub count" {
  # Same class as the entry-set find: the "did protoc actually generate anything?"
  # guard counted names, so a directory ending in .php passed it and an empty
  # package was published.
  seed_default_protos
  stage_php
  mkdir -p "$SANDBOX/shim"
  cat > "$SANDBOX/shim/protoc" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in --php_out=*) mkdir -p "${a#--php_out=}/NotAFile.php" ;; esac
done
exit 0
EOF
  chmod +x "$SANDBOX/shim/protoc"
  PATH="$SANDBOX/shim:$PATH"
  export PATH

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"produced no .php files"* ]]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]
  [ ! -s "$COMPOSER_MOCK_LOG" ]
  [ ! -e "$OUT/composer.json" ]
}

@test "php guard: a missing protos dir fails loudly before protoc is called" {
  mkdir -p "$IN/other"
  printf 'x\n' > "$IN/other/keep.txt"
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
  [ ! -s "$COMPOSER_MOCK_LOG" ]
}

@test "php guard: protoc producing no .php files aborts before the package build" {
  seed_default_protos
  stage_php
  # a protoc that succeeds but emits nothing - the stub-count guard is the only
  # thing standing between that and an empty package being published
  mkdir -p "$SANDBOX/shim"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SANDBOX/shim/protoc"
  chmod +x "$SANDBOX/shim/protoc"
  PATH="$SANDBOX/shim:$PATH"
  export PATH

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"produced no .php files"* ]]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]
  [ ! -s "$COMPOSER_MOCK_LOG" ]
}

# =====================================================================
# The protoc invocation itself
# =====================================================================

@test "php protoc: exactly one call carrying both _out flags and the grpc plugin" {
  seed_default_protos
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  # one call over the whole resolved set - deliberately not typescript's
  # two-call split, which can hand protoc an empty file list
  [ "$(count_matches '^protoc ' "$PROTOC_MOCK_LOG")" -eq 1 ]

  run grep -Fq -- "--php_out=$TEMP/generated-src" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "--grpc_out=$TEMP/generated-src" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # the default container path of the plugin, handed to protoc and never exec'd
  run grep -Fq -- "--plugin=protoc-gen-grpc=/usr/bin/grpc_php_plugin" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "-I $IN/protos " "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # both protos of the entry set, root-relative
  run grep -Fq -- " test.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- " dependency/myimport.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "php protoc: the grpc plugin path is env-overridable (CONTRACT rule 5)" {
  seed_default_protos
  stage_php
  export GRPC_PHP_PLUGIN="$SANDBOX/fake-grpc-php-plugin"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  run grep -Fq -- "--plugin=protoc-gen-grpc=$SANDBOX/fake-grpc-php-plugin" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "php protoc: imported google/protobuf well-known types are NOT recompiled" {
  # Load-bearing for PHP: the well-known types ship as classes inside the
  # google/protobuf composer package; regenerating them produces duplicate class
  # declarations that fatal at autoload.
  write_proto "$IN/api/google/protobuf/empty.proto" google.protobuf
  write_proto "$IN/api/google/protobuf/timestamp.proto" google.protobuf
  write_proto "$IN/api/google/api/annotations.proto" google.api
  write_proto "$IN/api/ondewo/nlu/session.proto" ondewo.nlu \
    "google/protobuf/empty.proto" "google/protobuf/timestamp.proto" "google/api/annotations.proto"
  stage_php

  run bash ./compile-proto-2-php.sh api ondewo
  [ "$status" -eq 0 ]

  run grep -Fq -- "google/protobuf/empty.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  run grep -Fq -- "google/protobuf/timestamp.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
  # the mirror image: an imported NON-well-known google proto must be generated,
  # because a generated descriptor's initOnce() calls into it
  run grep -Fq -- " google/api/annotations.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "php protoc: a transitive chain is followed to the end, including a sibling-relative import" {
  # a.proto -> dep/b.proto -> c.proto. The first hop is spelled against the proto
  # ROOT (what protoc's -I resolves), the second only exists NEXT TO the importing
  # file, which is the resolver's second, file-relative lookup. Only a.proto is in
  # the entry set (the run is scoped to ondewo/), so both hops are reached purely by
  # recursion - and the whole closure has to arrive at protoc, root-relative.
  write_proto "$IN/api/ondewo/a.proto" ondewo "dep/b.proto"
  write_proto "$IN/api/dep/b.proto" dep "c.proto"
  write_proto "$IN/api/dep/c.proto" dep
  stage_php

  run bash ./compile-proto-2-php.sh api ondewo
  [ "$status" -eq 0 ]

  # the entry set is the scoped sub-tree alone ...
  [[ "$output" == *"Found 1 .proto files"* ]]
  # ... and the closure adds both hops, each exactly once
  [[ "$output" == *"Consuming 3 .proto files"* ]]

  [ "$(count_matches '^protoc ' "$PROTOC_MOCK_LOG")" -eq 1 ]
  run grep -Fq -- " ondewo/a.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- " dep/b.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # the grandchild, resolved relative to dep/b.proto and still named relative to
  # the -I root (a file-relative name would make protoc fail on the real toolchain)
  run grep -Fq -- " dep/c.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- " c.proto " "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "php protoc: an unresolvable import aborts the stub step" {
  write_proto "$IN/protos/test.proto" example "nowhere/missing.proto"
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"Failed to resolve dependency"* ]]
  [[ "$output" == *"compile-proto-2-stubs.sh failed"* ]]
  [ ! -s "$COMPOSER_MOCK_LOG" ]
}

@test "php protoc: an UNSCOPED run still generates a vendored google proto nothing imports" {
  # This is the whole reason the entry-set filter is `*/google/protobuf/*` and not
  # java's blanket `*/google/*`. For an IMPORTED google proto the entry filter is
  # irrelevant (the dependency resolver adds it, with the same exclusion), so the
  # difference shows up only here: an unscoped run over a vendored api tree, where
  # the entry set is the only thing that can reach google/api or google/rpc. php
  # needs them generated - only google/protobuf ships as a composer package.
  write_proto "$IN/protos/google/protobuf/empty.proto" google.protobuf
  write_proto "$IN/protos/google/api/annotations.proto" google.api
  write_proto "$IN/protos/google/rpc/status.proto" google.rpc
  write_proto "$IN/protos/test.proto" example
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  run grep -Fq -- " google/api/annotations.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- " google/rpc/status.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -eq 0 ]
  # while the well-known types stay out
  run grep -Fq -- "google/protobuf/empty.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "BUG: google/protobuf protos in the entry set are compiled when no target subdir is given" {
  write_proto "$IN/protos/google/protobuf/empty.proto" google.protobuf
  write_proto "$IN/protos/test.proto" example
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  run grep -Fq -- "google/protobuf/empty.proto" "$PROTOC_MOCK_LOG"
  [ "$status" -ne 0 ]
}

# =====================================================================
# Failure propagation
# =====================================================================

@test "php failure: a missing input volume fails loudly" {
  stage_php
  export INPUT_VOLUME_FS="$SANDBOX/no-such-mount"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"input volume"* ]]
  [[ "$output" == *"does not exist"* ]]
}

@test "php failure: an empty input volume fails loudly" {
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to copy the contents of the input volume"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "php failure: a default library manifest missing from the image fails loudly" {
  seed_default_protos
  stage_php
  rm -f "$SANDBOX/image-data/default-lib-files/composer.json"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"default library manifest"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "php failure: a malformed client composer.json aborts at the entry-point step" {
  seed_default_protos
  printf '{ this is not json\n' > "$IN/composer.json"
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"make-lib-entry-point.sh failed"* ]]
  # the stub step had already run; the package build must not have
  [ ! -s "$COMPOSER_MOCK_LOG" ]
  [ ! -e "$OUT/composer.json" ]
}

@test "php failure: composer validate failing aborts the entrypoint" {
  seed_default_protos
  stage_php
  export COMPOSER_FAIL_MATCH="validate"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not valid"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
  [ ! -e "$OUT/composer.json" ]
}

@test "php failure: an offline dependency miss (composer update) aborts the entrypoint" {
  seed_default_protos
  stage_php
  export COMPOSER_FAIL_MATCH="update"
  export COMPOSER_FAIL_RC=2

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs an image rebuild"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
  [ ! -e "$OUT/vendor" ]
}

@test "php failure: composer dump-autoload failing aborts the entrypoint" {
  seed_default_protos
  stage_php
  export COMPOSER_FAIL_MATCH="dump-autoload"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"optimized autoloader"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
}

@test "php failure: the stub-load verification failing aborts before anything is published" {
  seed_default_protos
  stage_php
  export PHP_MOCK_RC=3

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -ne 0 ]
  [[ "$output" == *"generated stubs failed to load"* ]]
  [[ "$output" == *"compile-stubs-2-lib.sh failed"* ]]
  [ ! -e "$OUT/composer.json" ]
  [ ! -e "$OUT/src" ]
}

# =====================================================================
# Sub-script contracts (usage + preconditions)
# =====================================================================

@test "php sub-script: compile-proto-2-stubs.sh rejects missing arguments" {
  run bash "$REPO_ROOT/php/image-data/compile-proto-2-stubs.sh" "$SANDBOX/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-proto-2-stubs.sh"* ]]
  [ ! -s "$PROTOC_MOCK_LOG" ]
}

@test "php sub-script: compile-stubs-2-lib.sh rejects a missing argument" {
  run bash "$REPO_ROOT/php/image-data/compile-stubs-2-lib.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: compile-stubs-2-lib.sh"* ]]
  [ ! -s "$COMPOSER_MOCK_LOG" ]
}

@test "php sub-script: compile-stubs-2-lib.sh refuses to build without generated stubs" {
  mkdir -p "$SANDBOX/work"
  printf '{"name":"x/y"}\n' > "$SANDBOX/work/composer.json"

  run bash "$REPO_ROOT/php/image-data/compile-stubs-2-lib.sh" "$SANDBOX/work"
  [ "$status" -ne 0 ]
  [[ "$output" == *"generated-src"* ]]
  [ ! -s "$COMPOSER_MOCK_LOG" ]
}

@test "php sub-script: compile-stubs-2-lib.sh refuses to build without a manifest" {
  mkdir -p "$SANDBOX/work/generated-src"
  printf '<?php\n' > "$SANDBOX/work/generated-src/Stub.php"

  run bash "$REPO_ROOT/php/image-data/compile-stubs-2-lib.sh" "$SANDBOX/work"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no library manifest"* ]]
  [ ! -s "$COMPOSER_MOCK_LOG" ]
}

@test "php sub-script: compile-stubs-2-lib.sh replaces, not merges, a stale staged lib/src" {
  mkdir -p "$SANDBOX/work/generated-src/Mock" "$SANDBOX/work/lib/src/Gone"
  printf '<?php\n' > "$SANDBOX/work/generated-src/Mock/New.php"
  printf '<?php\n' > "$SANDBOX/work/lib/src/Gone/Old.php"
  printf '{"name":"x/y","autoload":{"classmap":["src/"]}}\n' > "$SANDBOX/work/composer.json"

  run bash "$REPO_ROOT/php/image-data/compile-stubs-2-lib.sh" "$SANDBOX/work"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/work/lib/src/Mock/New.php" ]
  [ ! -e "$SANDBOX/work/lib/src/Gone" ]
}

@test "php sub-script: make-lib-entry-point.sh rejects a missing argument" {
  run bash "$REPO_ROOT/php/image-data/make-lib-entry-point.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: make-lib-entry-point.sh <temp_src_directory>"* ]]
  # the argument check comes first: with no source directory there is nothing to
  # look the image default up against, so that error must not be the one reported
  [[ "$output" != *"default library manifest"* ]]
  [ ! -s "$COMPOSER_MOCK_LOG" ]
}

@test "php sub-script: make-lib-entry-point.sh rejects a missing source directory" {
  run bash "$REPO_ROOT/php/image-data/make-lib-entry-point.sh" "$SANDBOX/nope" \
    "$REPO_ROOT/php/image-data/default-lib-files"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "php sub-script: make-lib-entry-point.sh rejects a missing image default manifest" {
  mkdir -p "$SANDBOX/work"
  run bash "$REPO_ROOT/php/image-data/make-lib-entry-point.sh" "$SANDBOX/work" "$SANDBOX/nope"
  [ "$status" -ne 0 ]
  [[ "$output" == *"default library manifest"* ]]
}

# =====================================================================
# Library manifest: image default vs. client merge
# =====================================================================

@test "php manifest: without a client composer.json the image default is installed verbatim" {
  seed_default_protos
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  [ "$(jq -r '.name' "$OUT/composer.json")" = "ondewo/proto-compiler-php-lib" ]
  [ "$(jq -r '.autoload.classmap | join(",")' "$OUT/composer.json")" = "src/" ]
  [ "$(jq -r '.require["ext-grpc"]' "$OUT/composer.json")" = "*" ]
  [ "$(jq -r '.license' "$OUT/composer.json")" = "Apache-2.0" ]
}

@test "php manifest: a client manifest is merged - its own fields and version pins win" {
  seed_default_protos
  cat > "$IN/composer.json" <<'JSON'
{
  "name": "ondewo/nlu-client-php",
  "description": "client",
  "require": { "google/protobuf": "^3.25", "monolog/monolog": "^3.0" },
  "autoload": { "psr-4": { "Ondewo\\Auth\\": "auth/" }, "classmap": ["auth/"] }
}
JSON
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  # the client manifest is the base: its identity survives
  [ "$(jq -r '.name' "$OUT/composer.json")" = "ondewo/nlu-client-php" ]
  [ "$(jq -r '.description' "$OUT/composer.json")" = "client" ]
  # its pin beats the image default ...
  [ "$(jq -r '.require["google/protobuf"]' "$OUT/composer.json")" = "^3.25" ]
  # ... its extra requirement is kept ...
  [ "$(jq -r '.require["monolog/monolog"]' "$OUT/composer.json")" = "^3.0" ]
  # ... and the image defaults it did not override are still there
  [ "$(jq -r '.require["ext-grpc"]' "$OUT/composer.json")" = "*" ]
  [ "$(jq -r '.require | has("grpc/grpc")' "$OUT/composer.json")" = "true" ]
  # autoload comes from the client, but src/ is forced in (it is compiler-owned)
  [ "$(jq -r '.autoload["psr-4"]["Ondewo\\Auth\\"]' "$OUT/composer.json")" = "auth/" ]
  [ "$(jq -r '.autoload.classmap | index("src/") != null' "$OUT/composer.json")" = "true" ]
  [ "$(jq -r '.autoload.classmap | index("auth/") != null' "$OUT/composer.json")" = "true" ]
}

@test "php manifest: src/ is forced into a client classmap that omits it, without duplication" {
  seed_default_protos
  printf '{"name":"c/p","autoload":{"psr-4":{"A\\\\":"a/"}}}\n' > "$IN/composer.json"
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  [ "$(jq -r '.autoload.classmap | join(",")' "$OUT/composer.json")" = "src/" ]
  [ "$(jq -r '.autoload["psr-4"]["A\\"]' "$OUT/composer.json")" = "a/" ]
}

@test "php manifest: a client classmap that already lists src/ is not duplicated" {
  seed_default_protos
  printf '{"name":"c/p","autoload":{"classmap":["src/"]}}\n' > "$IN/composer.json"
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  [ "$(jq -r '[.autoload.classmap[] | select(. == "src/")] | length' "$OUT/composer.json")" = "1" ]
}

@test "php manifest: every placeholder in the shipped default is substituted by the Dockerfile" {
  # The @NAME@ placeholders are resolved at image-build time, so the manifest the
  # host suite drives still carries them; an unmatched one would ship a literal
  # "@GRPC_PHP_VERSION@" as a composer constraint.
  manifest="$REPO_ROOT/php/image-data/default-lib-files/composer.json"
  placeholders="$(sed -n 's|.*@\([A-Z0-9_]*\)@.*|\1|p' "$manifest" | sort -u)"
  [ -n "$placeholders" ]
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    run grep -Fq -- "s|@${name}@|" "$REPO_ROOT/php/Dockerfile"
    [ "$status" -eq 0 ]
    run grep -Eq "^ARG ${name}=" "$REPO_ROOT/php/Dockerfile"
    [ "$status" -eq 0 ]
  done <<< "$placeholders"
}

# =====================================================================
# Registering the client's hand-written auth/ with the shipped autoloader
# =====================================================================

@test "php auth: hand-written auth/ is added to the shipped classmap and the autoloader is re-dumped" {
  seed_default_protos
  stage_php
  install_composer_env_probe
  mkdir -p "$OUT/auth"
  printf '<?php\nclass TokenProvider {}\n' > "$OUT/auth/TokenProvider.php"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  [[ "$output" == *"adding them to the library autoloader"* ]]

  [ "$(jq -r '.autoload.classmap | index("auth/") != null' "$OUT/composer.json")" = "true" ]
  [ "$(jq -r '.autoload.classmap | index("src/") != null' "$OUT/composer.json")" = "true" ]

  # a fourth composer call, made in the OUTPUT volume and still offline
  [ "$(count_matches '^composer ' "$COMPOSER_MOCK_LOG")" -eq 4 ]
  [[ "$(tail -n 1 "$COMPOSER_MOCK_LOG")" == "composer dump-autoload --optimize"* ]]
  last_env="$(tail -n 1 "$COMPOSER_ENV_MOCK_LOG")"
  [ "${last_env%%|*}" = "$OUT" ]
  [[ "$last_env" == *"|1|dump-autoload"* ]]
}

@test "php auth: without auth/ the manifest is left alone and composer runs exactly three times" {
  seed_default_protos
  stage_php

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  [[ "$output" != *"adding them to the library autoloader"* ]]
  [ "$(count_matches '^composer ' "$COMPOSER_MOCK_LOG")" -eq 3 ]
  [ "$(jq -r '.autoload.classmap | index("auth/") != null' "$OUT/composer.json")" = "false" ]
}

@test "php auth: registering auth/ is idempotent across runs" {
  seed_default_protos
  # a client manifest that already lists auth/, plus the directory itself:
  # both the merge step and the post-copy jq add it, so `unique` is what keeps
  # the classmap from growing on every run
  printf '{"name":"c/p","autoload":{"classmap":["auth/"]}}\n' > "$IN/composer.json"
  stage_php
  mkdir -p "$OUT/auth"
  printf '<?php\nclass TokenProvider {}\n' > "$OUT/auth/TokenProvider.php"

  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]
  rm -rf "$TEMP"
  run bash ./compile-proto-2-php.sh protos
  [ "$status" -eq 0 ]

  [ "$(jq -r '[.autoload.classmap[] | select(. == "auth/")] | length' "$OUT/composer.json")" = "1" ]
  [ "$(jq -r '[.autoload.classmap[] | select(. == "src/")] | length' "$OUT/composer.json")" = "1" ]
  [ -f "$OUT/auth/TokenProvider.php" ]
}

# =====================================================================
# build.sh / Makefile / example wrapper (docker-facing, PATH-mocked docker)
# =====================================================================

@test "php Makefile: run builds CWD-relative mounts and passes the protos dir basename" {
  # PROTO_DIR / OUTPUT_DIR are relative to the caller's CWD (the mounts are
  # built as ${shell pwd}/${VAR}, exactly like python/Makefile), so an absolute
  # override would produce a doubled mount source.
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  mkdir -p "$SANDBOX/example/protos"
  cd "$SANDBOX"

  run make -f "$REPO_ROOT/php/Makefile" run
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/output" ]

  run grep -Fq -- "-v $SANDBOX/example/protos:/input-volume/protos" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "-v $SANDBOX/output:/output-volume" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  # the entrypoint receives the basename of the mounted protos dir
  run grep -Fq -- "ondewo-php-proto-compiler protos" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  # codegen must not be interactive and must not drop privileges (php output is
  # written by the container as root, like every node target)
  run grep -Eq -- "docker run( .*)? -it( |$)" "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
  run grep -Fq -- "--user" "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "php Makefile: run forwards TARGET_DIR as the optional second entrypoint argument" {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  mkdir -p "$SANDBOX/api"
  cd "$SANDBOX"

  run make -f "$REPO_ROOT/php/Makefile" run PROTO_DIR=api TARGET_DIR=ondewo OUTPUT_DIR=gen
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/gen" ]

  run grep -Fq -- "-v $SANDBOX/api:/input-volume/api" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "-v $SANDBOX/gen:/output-volume" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "ondewo-php-proto-compiler api ondewo" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "php build.sh: propagates a failing docker build and prints no success banner" {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  FAIL_BUILD_MATCH="ondewo-php-proto-compiler" run sh "$REPO_ROOT/php/build.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"✅"* ]]
  run grep -Fq -- "build --no-cache -t ondewo-php-proto-compiler:latest" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "php example: builds well-formed mounts and never uses -it on the codegen run" {
  export DOCKER_MOCK_LOG="$SANDBOX/docker.log"
  cp "$REPO_ROOT/php/example/run-compile.sh" "$SANDBOX/run.sh"

  run bash "$SANDBOX/run.sh"
  [ "$status" -eq 0 ]
  [ -d "$SANDBOX/lib" ]

  run grep -Fq -- "-v $SANDBOX:/input-volume" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  run grep -Fq -- "-v $SANDBOX/lib:/output-volume" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
  # no doubled path from a mis-resolved script dir
  run grep -Fq -- "-v $SANDBOX/$SANDBOX" "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
  # -it breaks every non-interactive caller ("cannot attach stdin to a TTY")
  run grep -Fq -- "docker run -it" "$DOCKER_MOCK_LOG"
  [ "$status" -ne 0 ]
  # the entrypoint gets the relative protos dir
  run grep -Fq -- "ondewo-php-proto-compiler protos" "$DOCKER_MOCK_LOG"
  [ "$status" -eq 0 ]
}
