#!/usr/bin/env bats
# Cheap, no-build static checks over the Dockerfiles + Makefile (a hadolint
# substitute). Guards the Dockerfile-hygiene fixes, the Node version split and -
# now that there are eleven language targets - the wiring that keeps a target
# from silently escaping the release rewrite or the build-all fan-out.
#
# Everything is discovered from the directory tree rather than a hard-coded list
# of languages, so a twelfth target is covered the day its directory lands.

load 'helpers/setup'

setup() { common_setup; }
teardown() { common_teardown; }

# --------------------------------------------------------------------------
# Discovery helpers
#
# Discovery goes through the filesystem, NOT `git ls-files`: common_setup puts
# the PATH mocks first and the mock git answers `ls-files` with silence, which
# would turn every loop below into a vacuous pass.
# --------------------------------------------------------------------------

# Every language target directory: a top-level dir that ships a build.sh and a
# Dockerfile. Sorted basenames, one per line.
lang_targets() {
  local d
  for d in "$REPO_ROOT"/*/; do
    d="${d%/}"
    [ -f "$d/build.sh" ] || continue
    [ -f "$d/Dockerfile" ] || continue
    echo "${d##*/}"
  done | sort
}

# Every production Dockerfile, repo-relative: the per-language ones plus the root
# utils image. tests/fixtures/ ships Dockerfile.utils stubs for the release
# tests - those are fixtures, not images this repo builds, so they stay out.
prod_dockerfiles() {
  local f d
  for f in "$REPO_ROOT"/Dockerfile*; do
    if [ -f "$f" ]; then echo "${f##*/}"; fi
  done
  for d in $(lang_targets); do
    echo "$d/Dockerfile"
  done
}

# Every ARG name declared by a production Dockerfile.
declared_dockerfile_args() {
  local f
  cd "$REPO_ROOT" || return 1
  for f in $(prod_dockerfiles); do
    sed -n 's|^ARG \([A-Za-z_][A-Za-z0-9_]*\)=.*|\1|p' "$f"
  done | sort -u
}

# The NAME half of every NAME=VALUE pair in the Makefile's DOCKERFILE_ARGS list
# (the backslash-continued block the release target feeds to its perl rewrite).
makefile_dockerfile_args() {
  awk '/^DOCKERFILE_ARGS[[:space:]]*=/ { inblk = 1 }
       inblk { print; if ($0 !~ /\\[[:space:]]*$/) exit }' "$REPO_ROOT/Makefile" |
    sed -n 's|^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)=.*|\1|p' | sort -u
}

# The file list of the Makefile's DOCKERFILES variable.
makefile_dockerfiles() {
  awk '/^DOCKERFILES[[:space:]]*=/ { inblk = 1 }
       inblk { print; if ($0 !~ /\\[[:space:]]*$/) exit }' "$REPO_ROOT/Makefile" |
    sed -n 's|^[[:space:]]*\([A-Za-z0-9_./-]*Dockerfile[A-Za-z0-9_.]*\).*|\1|p' | sort -u
}

# A whitespace-separated language list, one per line and sorted.
as_sorted_lines() {
  local w
  for w in $1; do echo "$w"; done | sort
}

# --------------------------------------------------------------------------
# Version pinning
# --------------------------------------------------------------------------

@test "mk-6: node Dockerfiles pin the same NODE_VERSION as the Makefile" {
  ver=$(grep -E '^NODE_VERSION=' "$REPO_ROOT/Makefile" | head -1 | cut -d= -f2)
  [ -n "$ver" ]
  for df in angular js nodejs typescript; do
    run grep -Fxq "ARG NODE_VERSION=$ver" "$REPO_ROOT/$df/Dockerfile"
    [ "$status" -eq 0 ]
  done
}

@test "every Dockerfile ARG is release-managed by the Makefile's DOCKERFILE_ARGS" {
  # A pin that is declared in a Dockerfile but missing from DOCKERFILE_ARGS is
  # invisible to `make release_version_update_in_dockerfiles`: it keeps whatever
  # literal the author typed and silently drifts from the Makefile forever.
  #
  # Exemptions are ARGs that are an identity rather than a version, so there is
  # nothing for the release rewrite to propagate into them. Keep this list
  # closed - a version-shaped name landing here is a release-escape bug, not an
  # exemption.
  local exempt=" ONDEWO_PACKAGE_ID "
  local managed missing=""
  managed=" $(makefile_dockerfile_args | tr '\n' ' ')"

  [ -n "$(makefile_dockerfile_args)" ]   # the awk/sed extraction still works

  local name
  for name in $(declared_dockerfile_args); do
    case "$managed" in *" $name "*) continue ;; esac
    case "$exempt" in *" $name "*) continue ;; esac
    missing="$missing $name"
  done
  echo "ARGs not covered by DOCKERFILE_ARGS:$missing"
  [ -z "$missing" ]
}

@test "every production Dockerfile is listed in the Makefile's DOCKERFILES" {
  # The release target already fails loudly on a listed-but-missing file; this is
  # the other direction - a new target's Dockerfile that nobody added to the list.
  local listed unlisted="" f
  listed=" $(makefile_dockerfiles | tr '\n' ' ')"
  [ -n "$(makefile_dockerfiles)" ]
  for f in $(prod_dockerfiles); do
    case "$listed" in *" $f "*) continue ;; esac
    unlisted="$unlisted $f"
  done
  echo "Dockerfiles missing from DOCKERFILES:$unlisted"
  [ -z "$unlisted" ]
}

# --------------------------------------------------------------------------
# ENTRYPOINT / image-data
# --------------------------------------------------------------------------

@test "py-1: python Dockerfile uses exec-form ENTRYPOINT" {
  run grep -Eq '^ENTRYPOINT \[' "$REPO_ROOT/python/Dockerfile"
  [ "$status" -eq 0 ]
}

@test "no shell-form ENTRYPOINT in any Dockerfile" {
  local df count=0
  for df in $(prod_dockerfiles); do
    count=$((count + 1))
    # every ENTRYPOINT line must be the exec-form JSON array
    run bash -c "grep -E '^ENTRYPOINT' '$REPO_ROOT/$df' | grep -vE '^ENTRYPOINT \['"
    echo "$df: $output"
    [ -z "$output" ]
  done
  # eleven language images + Dockerfile.utils; guards against an empty scan
  [ "$count" -ge 12 ]
}

@test "every language image declares exactly one ENTRYPOINT" {
  local lang n
  for lang in $(lang_targets); do
    n=$(grep -cE '^ENTRYPOINT ' "$REPO_ROOT/$lang/Dockerfile" || true)
    echo "$lang: $n ENTRYPOINT line(s)"
    [ "$n" -eq 1 ]
  done
}

@test "each ENTRYPOINT runs that target's own orchestrator script" {
  # A copy-pasted Dockerfile that still starts the previous language's
  # orchestrator builds fine and only explodes at `docker run` time.
  local lang orchestrator checked=0
  for lang in $(lang_targets); do
    orchestrator="image-data/compile-proto-2-${lang}.sh"
    [ -f "$REPO_ROOT/$lang/$orchestrator" ] || continue   # python entry is `make generate_protos`
    checked=$((checked + 1))
    run grep -Fxq "ENTRYPOINT [\"bash\",\"compile-proto-2-${lang}.sh\"]" "$REPO_ROOT/$lang/Dockerfile"
    echo "$lang ENTRYPOINT: $(grep -E '^ENTRYPOINT ' "$REPO_ROOT/$lang/Dockerfile")"
    [ "$status" -eq 0 ]
  done
  [ "$checked" -ge 10 ]
}

@test "image-data is copied with the COPY directory form wherever a target ships one" {
  # Both directions: a target with an image-data/ tree must copy it in, and a
  # target without one (python, whose entry point is its Makefile) must not
  # claim to - a COPY of a non-existent path fails the build.
  local lang checked=0
  for lang in $(lang_targets); do
    if [ -d "$REPO_ROOT/$lang/image-data" ]; then
      checked=$((checked + 1))
      run grep -Eq '^COPY image-data/ /image-data/' "$REPO_ROOT/$lang/Dockerfile"
      echo "$lang: missing 'COPY image-data/ /image-data/'"
      [ "$status" -eq 0 ]
    else
      run grep -Eq '^COPY image-data' "$REPO_ROOT/$lang/Dockerfile"
      echo "$lang: copies image-data/ but ships no such directory"
      [ "$status" -ne 0 ]
    fi
  done
  [ "$checked" -ge 10 ]
}

@test "js-1: js Dockerfile has no invalid 'npm install -g -D ... --yes'" {
  run grep -Eq 'npm install -g -D|--yes' "$REPO_ROOT/js/Dockerfile"
  [ "$status" -ne 0 ]
}

@test "js-2: no 'ADD image-data/*' wildcard that flattens default-lib-files" {
  run grep -Eq '^ADD image-data/\* ' "$REPO_ROOT/js/Dockerfile"
  [ "$status" -ne 0 ]
}

# --------------------------------------------------------------------------
# Build-system wiring
# --------------------------------------------------------------------------

@test "the language target set agrees across disk, Makefile, build-all.sh and build-all.bat" {
  local on_disk make_langs sh_langs bat_langs
  on_disk=$(lang_targets)
  # a discovery helper that quietly returns nothing would make every set "agree"
  [ "$(echo "$on_disk" | grep -c .)" -ge 11 ]

  make_langs=$(as_sorted_lines "$(sed -n 's|^PROGRAMMING_LANGUAGES[[:space:]]*=[[:space:]]*||p' "$REPO_ROOT/Makefile")")
  sh_langs=$(as_sorted_lines "$(sed -n 's|^for lang in \(.*\); do$|\1|p' "$REPO_ROOT/build-all.sh")")
  bat_langs=$(as_sorted_lines "$(sed -n 's|^for %%L in (\(.*\)) do (.*|\1|p' "$REPO_ROOT/build-all.bat")")

  echo "on disk:        $(echo "$on_disk" | tr '\n' ' ')"
  echo "Makefile:       $(echo "$make_langs" | tr '\n' ' ')"
  echo "build-all.sh:   $(echo "$sh_langs" | tr '\n' ' ')"
  echo "build-all.bat:  $(echo "$bat_langs" | tr '\n' ' ')"

  [ "$make_langs" = "$on_disk" ]
  [ "$sh_langs" = "$on_disk" ]
  [ "$bat_langs" = "$on_disk" ]
}

@test "every language target has a build_<lang> Makefile target that runs its own build.sh" {
  local lang
  for lang in $(lang_targets); do
    run grep -Eq "^build_${lang}:.*## " "$REPO_ROOT/Makefile"
    echo "Makefile has no documented build_${lang} target"
    [ "$status" -eq 0 ]
    run grep -Fq "cd ${lang} && sh build.sh" "$REPO_ROOT/Makefile"
    echo "build_${lang} does not run '${lang}/build.sh'"
    [ "$status" -eq 0 ]
  done
}

@test "no build_<lang> Makefile target points at a language directory that does not exist" {
  local on_disk=" " lang stale="" l
  for l in $(lang_targets); do on_disk="$on_disk$l "; done
  for lang in $(sed -n 's|^build_\([a-z0-9]*\): ## Build the .* proto compiler docker image.*|\1|p' "$REPO_ROOT/Makefile"); do
    case "$on_disk" in *" $lang "*) continue ;; esac
    stale="$stale $lang"
  done
  echo "build_<lang> targets without a directory:$stale"
  [ -z "$stale" ]
}
