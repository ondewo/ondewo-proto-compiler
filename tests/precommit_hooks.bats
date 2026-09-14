#!/usr/bin/env bats
# Static guard over .pre-commit-config.yaml's commit-msg stage.
#
# THREE hooks run there, in declaration order over the same message file:
#   strip-ticket-prefix (local) -> conventional-pre-commit -> giticket
# conventional-pre-commit anchors its regex at ^, so the validator has to see the
# developer's PLAIN subject. giticket prepends "[OND211-2418] " read out of the branch
# name, and the strip hook removes such a prefix left by an EARLIER run - without it an
# amend/reword re-validates the decorated subject and is rejected, and giticket's own
# idempotency guard never fires (its branch regex demands a - or _ after the ticket, and
# the closing bracket of an existing prefix is neither), so the prefix would double.
#
# Measured on a throwaway repo (both hooks installed via `pre-commit install
# --hook-type commit-msg`, branch feature/OND221-2830-something, subject
# "feat: add file one"):
#   giticket first       -> giticket Passed, Conventional Commit Failed,
#                           "[Bad commit message] >> [OND221-2830] feat: add file one",
#                           git commit exits 1 - i.e. EVERY commit on a ticket branch
#                           is blocked for anyone with the hooks installed.
#   conventional first   -> Conventional Commit Passed, giticket Passed,
#                           commit created as "[OND221-2830] feat: add file one".
# A non-conventional subject is still rejected either way, so the fix is an ordering
# change only - no check is weakened.
#
# NOTE: like tests/shellcheck.bats and tests/portability_static.bats, this file does
# NOT call common_setup - it only reads a tracked file and needs no mock PATH.

TESTS_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CFG="$REPO_ROOT/.pre-commit-config.yaml"

# First line number a pattern occurs on, or "" when absent.
line_of() {
  grep -n -- "$1" "$CFG" | head -1 | cut -d: -f1
}

@test "precommit-1: both commit-msg hooks are still declared" {
  [ -f "$CFG" ]
  run grep -Fq 'compilerla/conventional-pre-commit' "$CFG"
  [ "$status" -eq 0 ]
  run grep -Fq 'milin/giticket' "$CFG"
  [ "$status" -eq 0 ]
}

@test "precommit-2: conventional-pre-commit is declared BEFORE giticket" {
  conventional="$(line_of 'compilerla/conventional-pre-commit')"
  giticket="$(line_of 'milin/giticket')"
  [ -n "$conventional" ]
  [ -n "$giticket" ]
  # giticket rewrites the subject to "[TICKET] feat: ..." which conventional-pre-commit
  # rejects; declared in this order the validator judges the plain subject first.
  [ "$conventional" -lt "$giticket" ]
}

@test "precommit-3: conventional-pre-commit is not weakened into a warning" {
  # no --strict removal games: the hook must have no arg that relaxes the check, and
  # must stay pinned to the commit-msg stage where giticket also runs.
  run grep -Fq 'stages: [ commit-msg ]' "$CFG"
  [ "$status" -eq 0 ]
  ! grep -Eq '(verbose_output|always_run: *false).*conventional' "$CFG"
}

@test "precommit-4: giticket still prepends in the documented [ticket] format" {
  # CLAUDE.md tells contributors never to write the prefix by hand because this hook
  # adds it; if the format ever changes that instruction goes stale.
  run grep -Fq -- '--format=[{ticket}] {commit_msg}' "$CFG"
  [ "$status" -eq 0 ]
  run grep -Fq -- '--mode=regex_match' "$CFG"
  [ "$status" -eq 0 ]
}

@test "precommit-5: giticket's branch regex still matches the documented branch shapes" {
  # CLAUDE.md documents "(feature|bugfix|support|hotfix)/<TICKET>-..." and a bare
  # "<TICKET>-...". Assert the alternation and the optional-prefix group survive.
  run grep -Fq 'feature|bugfix|support|hotfix' "$CFG"
  [ "$status" -eq 0 ]
  run grep -Fq 'OND[0-9]{3}-[0-9]{1,5}' "$CFG"
  [ "$status" -eq 0 ]
}

@test "precommit-6: strip-ticket-prefix is declared FIRST of the three commit-msg hooks" {
  # Order is load-bearing: the strip hook must normalise the message before
  # conventional-pre-commit judges it, and before giticket decorates it again.
  cfg="$REPO_ROOT/.pre-commit-config.yaml"
  strip=$(grep -n 'id: strip-ticket-prefix' "$cfg" | cut -d: -f1)
  conv=$(grep -n 'id: conventional-pre-commit' "$cfg" | cut -d: -f1)
  tick=$(grep -n 'id: giticket' "$cfg" | cut -d: -f1)
  [ -n "$strip" ] && [ -n "$conv" ] && [ -n "$tick" ]
  [ "$strip" -lt "$conv" ]
  [ "$conv" -lt "$tick" ]
}

@test "precommit-6: the strip hook exists, is executable and runs at commit-msg" {
  [ -x "$REPO_ROOT/.hooks/strip-ticket-prefix.py" ]
  run grep -A5 'id: strip-ticket-prefix' "$REPO_ROOT/.pre-commit-config.yaml"
  [[ "$output" == *"stages: [ commit-msg ]"* ]]
  [[ "$output" == *".hooks/strip-ticket-prefix.py"* ]]
}

@test "precommit-7: the strip hook removes exactly one ticket prefix and nothing else" {
  msg="${BATS_TEST_TMPDIR}/msg.txt"
  # a decorated subject is reduced to the developer's own
  printf '[OND211-2418] feat: add a thing\n' > "$msg"
  run python3 "$REPO_ROOT/.hooks/strip-ticket-prefix.py" "$msg"
  [ "$status" -eq 0 ]
  [ "$(cat "$msg")" = "feat: add a thing" ]

  # an undecorated subject is passed through untouched
  printf 'feat: add a thing\n' > "$msg"
  python3 "$REPO_ROOT/.hooks/strip-ticket-prefix.py" "$msg"
  [ "$(cat "$msg")" = "feat: add a thing" ]

  # only the LEADING prefix goes; a ticket mentioned in the body survives
  printf 'feat: add a thing\n\nRelates to [OND211-2418] in the tracker.\n' > "$msg"
  python3 "$REPO_ROOT/.hooks/strip-ticket-prefix.py" "$msg"
  run grep -Fq 'Relates to [OND211-2418] in the tracker.' "$msg"
  [ "$status" -eq 0 ]

  # a doubled prefix loses exactly one, so the pipeline converges rather than oscillating
  printf '[OND211-2418] [OND211-2418] feat: add a thing\n' > "$msg"
  python3 "$REPO_ROOT/.hooks/strip-ticket-prefix.py" "$msg"
  [ "$(cat "$msg")" = "[OND211-2418] feat: add a thing" ]
}
