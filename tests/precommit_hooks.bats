#!/usr/bin/env bats
# Static guard over .pre-commit-config.yaml's commit-msg stage.
#
# Two hooks run there - conventional-pre-commit (validates the subject) and giticket
# (prepends "[OND211-2418] " read out of the branch name). pre-commit runs commit-msg
# hooks in DECLARATION ORDER over the same message file, and conventional-pre-commit
# anchors its regex at ^, so the validator has to see the developer's plain subject
# before giticket rewrites it.
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
