#!/usr/bin/env bats
# Static guard against macOS/BSD-hostile constructs in the repo's shell sources.
# These patterns behave differently (or fail) on BSD/macOS userland; some only
# surface at runtime on the macos-latest CI leg, so this cheap grep gate catches
# regressions on the Linux leg too.
#
# Scope: every tracked shell source - the production *.sh, AND the bats suite
# itself (*.bats, tests/helpers/setup.bash) AND the extension-less PATH-mocks
# under tests/helpers/bin. The suite is not exempt: .github/workflows/ci.yml
# runs `bats tests/` on a macos-latest runner, where the suite and its mocks
# execute against the BSD userland exactly like a production script does, so a
# GNU-ism in a test double breaks that leg just as hard. The one exclusion is
# THIS file, which is the catalogue of the forbidden patterns - every rule below
# would otherwise match its own definition.
#
# NOTE: like tests/shellcheck.bats, this file deliberately does NOT call
# common_setup - it needs the REAL git on PATH, not the mock, whose `ls-files`
# answers with silence and would turn every scan below into a vacuous pass.
# There are tests at the bottom that fail if the discovery ever goes empty.

load 'helpers/setup'

prod_scripts() {
  ( cd "$REPO_ROOT" && git ls-files '*.sh' | grep -v '^tests/' )
}

# Everything the rules below are enforced over: production scripts plus the
# suite (see the scope note in the header), minus this file.
scanned_scripts() {
  ( cd "$REPO_ROOT" \
      && git ls-files '*.sh' '*.bash' '*.bats' 'tests/helpers/bin/*' \
      | grep -v '^tests/portability_static\.bats$' )
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

# scan_for <extended-regex> : echo every "file:line:match" hit.
#
# Comment lines are ignored, and so are `@test "..." {` title lines: the only
# code on such a line is the braces, while the title routinely spells out the
# very construct the guard forbids ("never with BSD-padded 'wc -l'").
scan_for() {
  local re="$1" f
  cd "$REPO_ROOT" || return 1
  for f in $(scanned_scripts); do
    grep -nE "$re" "$f" 2>/dev/null | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*(#|@test )' | sed "s|^|$f:|"
  done
}

# scan_for_without <extended-regex> <required-extended-regex> : like scan_for,
# but a match only counts as a hit when the same line does NOT also match the
# second regex. Used where portability is about what a line is MISSING (an
# mktemp template) rather than about a token it contains.
scan_for_without() {
  local re="$1" required="$2" f
  cd "$REPO_ROOT" || return 1
  for f in $(scanned_scripts); do
    grep -nE "$re" "$f" 2>/dev/null \
      | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*(#|@test )' \
      | grep -vE "$required" | sed "s|^|$f:|"
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

@test "the scan covers the bats suite, its helpers and its PATH-mocks" {
  local scanned count
  scanned=$(scanned_scripts || true)
  count=$(echo "$scanned" | grep -c . || true)
  echo "scanned $count shell sources in total"
  # the production scripts plus ~30 .bats files, the helper lib and the mocks
  [ "$count" -ge 100 ]

  # the suite runs on the macos-latest CI leg, so it is in scope
  echo "$scanned" | grep -Fxq 'tests/helpers/setup.bash'
  echo "$scanned" | grep -Fxq 'tests/auth_exports.bats'
  # ... except this file: it is the catalogue of the patterns, not a user of them
  ! echo "$scanned" | grep -Fxq 'tests/portability_static.bats'
  # the PATH-mocks are shell scripts the scripts under test execute on that leg
  echo "$scanned" | grep -Fxq 'tests/helpers/bin/docker'
  echo "$scanned" | grep -Fxq 'tests/helpers/bin/protoc'
  # ... and so are the maintenance scripts under tests/, which prod_scripts skips
  echo "$scanned" | grep -Fxq 'tests/fixtures/presence/regenerate.sh'

  # every production script stays in scope as well
  local p
  for p in $(prod_scripts); do
    echo "$scanned" | grep -Fxq "$p"
  done
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

  # ... and the same holds once flags are in play: BSD mktemp prints its usage
  # and exits 1 for `mktemp -d` / `mktemp -u` just as it does for bare `mktemp`,
  # so require an XXXXXX template on EVERY line that invokes it.
  run scan_for_without '(^|[[:space:]$(`])mktemp([[:space:]]|\)|$)' 'XXXXXX'
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

@test "no GNU-only BRE escapes (backslash pipe / plus / question mark)" {
  # In a POSIX *basic* regex - what grep and sed take by default - \| \+ \? are
  # undefined. GNU reads them as alternation and the +/? quantifiers; BSD/macOS
  # matches the escaped character literally. So grep -c "spec\|test" counts
  # "spec|test" on macOS and silently answers 0, turning an assertion into a
  # vacuous pass instead of an error. Spell it grep -E / sed -E with plain
  # | + ?, or use two patterns.
  run scan_for '\\[|+?]'
  echo "$output"
  [ -z "$output" ]
}

@test "no 'wc -l' as a counter (BSD wc pads the count with leading spaces)" {
  # n=$(... | wc -l) is "3" on GNU but "       3" on BSD/macOS, so a later
  # string compare ([ "$n" = "3" ]) fails and a `test -eq` breaks outright under
  # dash. The repo standard is `... | grep -c . || true`.
  run scan_for 'wc[[:space:]]+-[a-zA-Z]*l'
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
