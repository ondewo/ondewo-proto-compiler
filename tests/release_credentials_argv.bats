#!/usr/bin/env bats
# Release credentials reach gh and docker through the environment, never through an argv.
#
# /proc/<pid>/cmdline is world-readable, so a token on docker's, make's or the shell's command line
# is visible to every user on the release host for the life of the process. make expands $(NAME)
# and ${NAME} in a recipe line BEFORE it runs `/bin/sh -c '<line>'`, so a secret make expands into a
# recipe lands on the shell's argv even when it is only piped into gh. A recipe reads a secret as
# $${NAME} (expanded by the shell from the exported environment), and docker forwards it by name
# only (`-e NAME`). Same contract as ondewo-client-utils-python's test_release_makefile_hygiene.py.

load 'helpers/setup'

setup() { common_setup; }
teardown() { common_teardown; }

SECRET='[A-Z0-9_]*(TOKEN|PASSWORD|USERNAME|SECRET|API_KEY)[A-Z0-9_]*'

# Every Makefile this repo ships (root + per-language), repo-relative.
makefiles() {
  local f
  for f in "$REPO_ROOT"/Makefile "$REPO_ROOT"/*/Makefile; do
    [ -f "$f" ] && echo "$f"
  done
}

@test "no recipe line lets make expand a credential onto the shell's argv" {
  local f leaks=""
  while read -r f; do
    # `$(if $(NAME),yes,no)` is evaluated by make; only yes/no reaches the shell.
    leaks+="$(grep -n "$(printf '^\t')" "$f" | sed -E "s/\\\$\\(if[[:space:]]+\\\$[({]${SECRET}[)}],//g" \
      | grep -E "(^|[^\$])\\\$[({]${SECRET}[)}]" || true)"
  done < <(makefiles)
  [ -z "$leaks" ] || { echo "$leaks"; false; }
}

@test "docker forwards credentials by name only and never takes one as a build arg" {
  run grep -n -E -- "(-e|--env)[[:space:]=]+${SECRET}=|--build-arg[[:space:]=]+${SECRET}" $(makefiles)
  [ "$status" -eq 1 ]
  grep -q -E -- '-e GITHUB_GH_TOKEN \\$' "$REPO_ROOT/Makefile"
}

@test "the root Makefile exports its variables to the recipes" {
  grep -q -E '^export[[:space:]]*$' "$REPO_ROOT/Makefile"
}

@test "no sub-make gets a credential or the old \$(info) bundle on its argv" {
  run bash -c "grep -n \"\$(printf '^\\t')\" $(makefiles | tr '\n' ' ') | grep -E '(^|[^A-Za-z_])make([^A-Za-z_]|$)|\\\$\\(MAKE\\)' \
    | grep -E '\\\$\\(info\\)|(^|[^A-Za-z0-9_])${SECRET}='"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "run_release_with_devops loads the anchored token line into the sub-make's environment" {
  local recipe
  recipe="$(awk '/^run_release_with_devops:/{f=1;next} f&&/^$/{exit} f' "$REPO_ROOT/Makefile")"
  [[ "$recipe" != *'$(info)'* ]]
  [[ "$recipe" != *'$(shell'* ]]
  [[ "$recipe" == *'set -a'* ]]
  [[ "$recipe" == *"grep -h -E '^GITHUB_GH_TOKEN='"* ]]
  [[ "$recipe" =~ \$\(MAKE\)\ release[[:space:]]*$ ]]
}

@test "gh reads the token on stdin, expanded by the shell" {
  grep -q -F "printf '%s\\n' \"\$\${GITHUB_GH_TOKEN}\" | gh auth login" "$REPO_ROOT/Makefile"
}

@test "no Dockerfile bakes a credential from a build arg" {
  run grep -n -E "^[[:space:]]*(ARG[[:space:]]+${SECRET}([[:space:]=]|$)|ENV[[:space:]]+${SECRET}[[:space:]=]+[^[:space:]]*\\\$)" \
    "$REPO_ROOT"/Dockerfile* "$REPO_ROOT"/*/Dockerfile
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "workflow run lines never interpolate a secret" {
  run bash -c "grep -h 'secrets\\.' '$REPO_ROOT'/.github/workflows/*.y*ml \
    | grep -v -E '^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*\\\$\\{\\{[[:space:]]*secrets\\.[A-Za-z0-9_]+[[:space:]]*\\}\\}[[:space:]]*$' \
    ; true"
  [ -z "$output" ] || { echo "$output"; false; }
  run grep -n -E '^[[:space:]]*run:.*secrets\.' "$REPO_ROOT"/.github/workflows/*.y*ml
  [ "$status" -eq 1 ]
}

@test "the release recipes run with a dummy token without putting it on any argv" {
  local repo="$SANDBOX/repo" mark="dummy-gh-token-$$-xyz"
  mkdir -p "$repo"
  # `release` itself is swapped for a probe that only checks the token arrived in its environment.
  sed 's/^release:/release_orig:/' "$REPO_ROOT/Makefile" > "$repo/Makefile"
  printf '\nrelease:\n\t@case "$$GITHUB_GH_TOKEN" in dummy-gh-token-*) echo TOKEN_IN_ENV;; esac\n' >> "$repo/Makefile"
  printf '# GITHUB_GH_TOKEN=a-comment-is-ignored\nGITHUB_GH_TOKEN=%s\n' "$mark" > "$repo/account_github.env"
  run env -u GITHUB_GH_TOKEN make -C "$repo" -s run_release_with_devops DEVOPS_ACCOUNT_DIR="$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *TOKEN_IN_ENV* ]]
  # `make -n` prints every recipe line as it would reach /bin/sh -c: the value must not be in any.
  run env GITHUB_GH_TOKEN="$mark" make -C "$repo" -n login_to_gh release_to_github_via_docker_image check_release_credentials
  [[ "$output" != *"$mark"* ]]
}
