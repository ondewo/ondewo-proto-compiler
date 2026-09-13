#!/usr/bin/env bats
# Static guard against macOS/BSD-hostile constructs in the production shell
# scripts. These patterns behave differently (or fail) on BSD/macOS userland;
# some only surface at runtime on the macos-latest CI leg, so this cheap grep
# gate catches regressions on the Linux leg too. Scope: tracked *.sh outside
# tests/ (the PATH-mocks under tests/helpers/bin are Linux-only test doubles).
#
# NOTE: like tests/shellcheck.bats, this file deliberately does NOT call
# common_setup - it needs the REAL git on PATH, not the mock, whose `ls-files`
# answers with silence and would turn every scan below into a vacuous pass.
# There is a test at the bottom that fails if the discovery ever goes empty.

load 'helpers/setup'

prod_scripts() {
  ( cd "$REPO_ROOT" && git ls-files '*.sh' | grep -v '^tests/' )
}

# Every language target directory: a top-level dir that ships a build.sh and a
# Dockerfile. Discovered from the filesystem so a new target is covered the day
# it lands.
lang_targets() {
  local d
  for d in "$REPO_ROOT"/*/; do
    d="${d%/}"
    if [ -f "$d/build.sh" ] && [ -f "$d/Dockerfile" ]; then echo "${d##*/}"; fi
  done | sort
}

# scan_for <extended-regex> : echo every "file:line:match" hit (ignoring comment lines)
scan_for() {
  local re="$1" f
  cd "$REPO_ROOT" || return 1
  for f in $(prod_scripts); do
    grep -nE "$re" "$f" 2>/dev/null | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
  done
}

# ---------------------------------------------------------------------------
# coverage: the scan must actually be looking at something
# ---------------------------------------------------------------------------

@test "the scan covers every language target's shell scripts" {
  local scanned count lang missing=""
  scanned=$(prod_scripts || true)
  count=$(echo "$scanned" | grep -c . || true)
  echo "scanned $count production scripts"
  # eleven targets x (build.sh + the image-data scripts) + the root scripts
  [ "$count" -ge 50 ]

  for lang in $(lang_targets); do
    if ! echo "$scanned" | grep -Fxq "${lang}/build.sh"; then
      missing="$missing ${lang}/build.sh"
    fi
  done
  echo "targets missing from the scan:$missing"
  [ -z "$missing" ]

  # the root orchestrator and the release script are in scope too
  echo "$scanned" | grep -Fxq 'build-all.sh'
  echo "$scanned" | grep -Fxq 'update_proto_compiler_dependency.sh'
}

# ---------------------------------------------------------------------------
# GNU-only tools and flags
# ---------------------------------------------------------------------------

@test "no grep -P / --perl-regexp (BSD grep has no PCRE)" {
  run scan_for 'grep[[:space:]]+(-[a-zA-Z]*P|--perl-regexp)'
  echo "$output"
  [ -z "$output" ]
}

@test "no realpath --relative-to (absent on BSD/macOS realpath)" {
  run scan_for 'realpath[[:space:]]+--relative-to'
  echo "$output"
  [ -z "$output" ]
}

@test "no readlink -f (BSD/macOS readlink lacks -f)" {
  run scan_for 'readlink[[:space:]]+-f'
  echo "$output"
  [ -z "$output" ]
}

@test "no find -printf (GNU-only extension)" {
  run scan_for 'find[[:space:]].*-printf'
  echo "$output"
  [ -z "$output" ]
}

@test "no bare mktemp without a template (BSD/macOS requires one)" {
  # portable form always has a XXXXXX template arg; flag the operand-less call
  run scan_for '\$\(mktemp\)|mktemp[[:space:]]*$'
  echo "$output"
  [ -z "$output" ]
}

@test "no bare 'sed -i ' in-place (BSD needs -i.bak / -i '')" {
  # this repo standardises on the portable `sed -i.bak ... && rm` idiom, which
  # has no space after -i; a space means the GNU-only bare form snuck back in
  run scan_for 'sed[[:space:]]+-i[[:space:]]'
  echo "$output"
  [ -z "$output" ]
}

@test "no 'xargs -I ... bash -c' cramming (BSD caps -I replacement at 255 bytes)" {
  run scan_for 'xargs[[:space:]].*-I[[:space:]].*bash[[:space:]]+-c'
  echo "$output"
  [ -z "$output" ]
}

@test "no sed -r / --regexp-extended (BSD sed spells it -E)" {
  run scan_for 'sed[[:space:]]+-[a-zA-Z]*r([[:space:]]|$)|--regexp-extended'
  echo "$output"
  [ -z "$output" ]
}

@test "no GNU-only stat/date/readlink/mktemp flags" {
  # stat -c, date -d, readlink -m, mktemp -p all mean something else (or
  # nothing) on BSD: stat uses -f, date uses -j -f, and there is no -m/-p.
  run scan_for 'stat[[:space:]]+-[a-zA-Z]*c|date[[:space:]]+-[a-zA-Z]*d|readlink[[:space:]]+-[a-zA-Z]*m|mktemp[[:space:]]+-[a-zA-Z]*p'
  echo "$output"
  [ -z "$output" ]
}

@test "no GNU-only checksum / reversal utilities (BSD ships md5, shasum, tail -r)" {
  run scan_for 'md5sum|sha1sum|sha256sum|sha512sum|(^|[[:space:]|(])tac([[:space:]]|$)'
  echo "$output"
  [ -z "$output" ]
}

@test "no GNU-only sort -V / xargs -r / head -n -N / cp --parents" {
  run scan_for 'sort[[:space:]]+-[a-zA-Z]*V|xargs[[:space:]]+-[a-zA-Z]*r|head[[:space:]]+-n[[:space:]]*-|--parents'
  echo "$output"
  [ -z "$output" ]
}

@test "no find without an explicit start path (BSD find requires one)" {
  run scan_for 'find[[:space:]]+-'
  echo "$output"
  [ -z "$output" ]
}

@test "no 'echo -e' (bash-as-sh on macOS prints the flag literally; use printf)" {
  run scan_for '(^|[[:space:]])echo[[:space:]]+-[eE]([[:space:]]|$)'
  echo "$output"
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# regex + shell dialect
# ---------------------------------------------------------------------------

@test "no \\s shorthand in a regex (BSD regex has no PCRE classes; use [[:space:]])" {
  run scan_for '\\s'
  echo "$output"
  [ -z "$output" ]
}

@test "no bash-4-only syntax (macOS ships bash 3.2)" {
  # ${*: -1} / ${arr[@]: -1}, associative arrays, ${var,,} and ${var^^} case
  # conversion, and mapfile/readarray all need bash 4.
  run scan_for '\$\{[*@]:[[:space:]]*-|(declare|local|typeset)[[:space:]]+-[a-zA-Z]*A|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|(^|[[:space:]|(])(mapfile|readarray)([[:space:]]|$)'
  echo "$output"
  [ -z "$output" ]
}
