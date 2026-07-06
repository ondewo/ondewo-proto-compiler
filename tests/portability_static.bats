#!/usr/bin/env bats
# Static guard against macOS/BSD-hostile constructs in the production shell
# scripts. These patterns behave differently (or fail) on BSD/macOS userland;
# some only surface at runtime on the macos-latest CI leg, so this cheap grep
# gate catches regressions on the Linux leg too. Scope: tracked *.sh outside
# tests/ (the PATH-mocks under tests/helpers/bin are Linux-only test doubles).

load 'helpers/setup'

prod_scripts() {
  ( cd "$REPO_ROOT" && git ls-files '*.sh' | grep -v '^tests/' )
}

# scan_for <extended-regex> : echo every "file:line:match" hit (ignoring comment lines)
scan_for() {
  local re="$1" f
  cd "$REPO_ROOT"
  for f in $(prod_scripts); do
    grep -nE "$re" "$f" 2>/dev/null | grep -vE '^\s*[0-9]+:\s*#' | sed "s|^|$f:|"
  done
}

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
