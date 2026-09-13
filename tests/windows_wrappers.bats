#!/usr/bin/env bats
# Static gate over the Windows batch wrappers: build-all.bat, every
# <lang>/build.bat and every <lang>/example/run-compile.bat.
#
# cmd.exe does not exist on the ubuntu-latest / macos-latest CI legs, so these
# wrappers are the one slice of the build tooling that no behavioural test can
# drive. They are therefore pinned STATICALLY, and the assertions are chosen to
# be the ones that would actually have caught a real regression:
#
#   * symmetry with the .sh scripts they mirror - a target that grows a build.sh
#     without a build.bat (or an example that grows a run-compile.sh without
#     one) is the failure mode this file exists to catch;
#   * error propagation - orch-1/orch-2 fixed exactly this on the sh side, and a
#     .bat that runs `docker build`, ignores ERRORLEVEL and falls through to its
#     "[OK] Done" banner is the same silent-failure bug in Windows clothing;
#   * drift - the image tag in build.bat and the image + entrypoint arguments in
#     run-compile.bat must stay byte-identical to their .sh counterparts,
#     otherwise the Windows path builds/runs a different image than CI does;
#   * cmd.exe-specific footguns that have no shell equivalent: `-it` on a
#     codegen `docker run` (RELEASE gotcha: "cannot attach stdin to a TTY"), the
#     `%~dp0\` double-backslash (%~dp0 ALREADY ends in a backslash), unquoted
#     -v mounts (Windows paths contain spaces), and an unguarded `mkdir` (cmd
#     sets ERRORLEVEL 1 when the directory already exists, so the very next
#     `if errorlevel 1` would abort every run after the first);
#   * line-ending / encoding hygiene - the repo keeps LF and the wrappers must
#     stay pure ASCII, because cmd.exe's default code page mangles the ✅ the
#     .sh banners use (hence `[OK]`).
#
# The custom detectors below (unguarded_invocations, tty_codegen_runs,
# unanchored_invocations, dp0_double_backslash) are themselves exercised against
# synthetic bad wrappers in the "negative control" tests at the bottom, so a
# detector that silently stopped matching cannot make this file pass vacuously.
#
# NOTE: like shellcheck.bats these tests deliberately do NOT call common_setup -
# they need the REAL git on PATH for `git ls-files`, not the release-test mock
# (which answers every unknown subcommand with a silent exit 0). Nothing here
# reads or writes through a mock, nothing writes into the repo tree, and the
# only writes at all go to a per-test mktemp sandbox used by the negative
# controls.

load 'helpers/setup'

setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/otcwin.XXXXXX")"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
  return 0
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Every .bat wrapper in the working tree, absolute paths, one per line.
# Enumerated with find (not a hardcoded list) so a newly added target is
# covered the moment it lands.
bat_files() {
  find "$REPO_ROOT" -name '*.bat' -not -path '*/.git/*' | sort
}

# Every language target = every directory that owns a Dockerfile one level
# below the repo root (tests/fixtures ships Dockerfile.utils, never Dockerfile).
target_dirs() {
  find "$REPO_ROOT" -mindepth 2 -maxdepth 2 -name 'Dockerfile' | sed 's|/Dockerfile$||' | sort
}

# A .bat's executable lines: `rem` / `REM` / `::` comment lines removed.
bat_code() {
  grep -v -i -E '^[[:space:]]*@?(rem([[:space:]]|$)|::)' "$1" || true
}

# A .sh's executable lines: `#` comment lines removed.
sh_code() {
  grep -v -E '^[[:space:]]*#' "$1" || true
}

# The image tag handed to `docker build -t` (first occurrence). Works for both
# flavours because the flag spelling is identical.
docker_build_tag() {
  case "$1" in
    *.bat) bat_code "$1" ;;
    *) sh_code "$1" ;;
  esac | grep -E '^[[:space:]]*docker[[:space:]]+build' \
       | sed -n 's/.*-t[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' \
       | head -1
}

# The codegen `docker run` invocation from the image name onward, i.e. the image
# plus the entrypoint arguments. The interactive `--entrypoint /bin/bash` debug
# form is excluded - it runs no entrypoint and takes no arguments.
codegen_run_args() {
  case "$1" in
    *.bat) bat_code "$1" ;;
    *) sh_code "$1" ;;
  esac | grep -E '^[[:space:]]*docker[[:space:]]+run' \
       | grep -v -- '--entrypoint' \
       | sed -n 's|.*\(ondewo-[a-z][a-z]*-proto-compiler\)|\1|p'
}

# Lines that launch something: `docker ...` or `call ...`. The interactive
# `--entrypoint /bin/bash` debug line is not codegen, so it is exempt.
invocation_count() {
  bat_code "$1" | grep -c -E '^[[:space:]]*(docker|call)[[:space:]]' || true
}

# Print every invocation in $1 that is NOT followed by an `if errorlevel 1`
# block that exits non-zero. The guard has to be the first thing after the
# invocation (before any further invocation), which is what makes a wrapper
# that runs two dockers and only checks the last one a failure.
unguarded_invocations() {
  bat_code "$1" | awk '
    function is_invocation(s) {
      if (s ~ /^[ \t]*docker[ \t]/ && index(s, "--entrypoint") == 0) return 1
      if (s ~ /^[ \t]*call[ \t]/) return 1
      return 0
    }
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (!is_invocation(line[i])) continue
        guard = 0
        for (j = i + 1; j <= NR; j++) {
          if (tolower(line[j]) ~ /if errorlevel 1/) { guard = j; break }
          if (is_invocation(line[j])) break
        }
        if (guard == 0) { print "no errorlevel guard after:" line[i]; continue }
        exits = 0
        for (k = guard; k <= guard + 3 && k <= NR; k++) {
          if (index(line[k], "exit /b 1") > 0) exits = 1
        }
        if (exits == 0) print "errorlevel guard does not exit non-zero after:" line[i]
      }
    }'
}

# Print every codegen `docker run` that carries -it. Only the
# `--entrypoint /bin/bash` debug line may.
tty_codegen_runs() {
  bat_code "$1" \
    | grep -E '^[[:space:]]*docker[[:space:]]+run' \
    | grep -E '(^|[[:space:]])-it([[:space:]]|$)' \
    | grep -v -F -- '--entrypoint /bin/bash' || true
}

# Print every docker/call line whose paths are not anchored on the script's own
# directory: neither a literal %~dp0 nor a variable this file assigns from
# %~dp0. That is the "never assume the caller's CWD" rule.
unanchored_invocations() {
  bat_code "$1" | awk '
    {
      line[NR] = $0
      if ($0 ~ /[Ss][Ee][Tt][ \t]+"?[A-Za-z_][A-Za-z_0-9]*=/ && index($0, "%~dp0") > 0) {
        name = $0
        sub(/^.*[Ss][Ee][Tt][ \t]+"?/, "", name)
        sub(/=.*$/, "", name)
        anchored[name] = 1
      }
    }
    END {
      for (i = 1; i <= NR; i++) {
        if (line[i] !~ /^[ \t]*(docker|call)[ \t]/) continue
        ok = (index(line[i], "%~dp0") > 0)
        for (v in anchored) {
          if (index(line[i], "%" v "%") > 0) ok = 1
        }
        if (!ok) print "unanchored:" line[i]
      }
    }'
}

# Print every `%~dp0\...` (or `%VAR%\...` where VAR holds an unstripped %~dp0).
# %~dp0 already ends in a backslash, so those expand to C:\path\\lib.
dp0_double_backslash() {
  grep -n -F -- '%~dp0\' "$1" || true
  local v
  for v in $(sed -n 's/^[[:space:]]*[Ss][Ee][Tt][[:space:]]*"\{0,1\}\([A-Za-z_][A-Za-z_0-9]*\)=%~dp0"\{0,1\}$/\1/p' "$1"); do
    # a later `%VAR:~0,-1%` strips the trailing backslash - then \ is correct
    if grep -q -F -- "%$v:~0,-1%" "$1"; then
      continue
    fi
    grep -n -F -- "%$v%\\" "$1" || true
  done
}

# ---------------------------------------------------------------------------
# symmetry: a missing wrapper is the failure mode this file exists to catch
# ---------------------------------------------------------------------------

@test "win-1: every target dir owns both build.sh and build.bat" {
  missing=""
  n=0
  for d in $(target_dirs); do
    n=$((n + 1))
    [ -f "$d/build.sh" ] || missing="$missing ${d#"$REPO_ROOT"/}/build.sh"
    [ -f "$d/build.bat" ] || missing="$missing ${d#"$REPO_ROOT"/}/build.bat"
  done
  echo "targets=$n missing:$missing"
  [ "$n" -ge 11 ]
  [ -z "$missing" ]
}

@test "win-2: no orphan build.bat - each one sits next to a build.sh and a Dockerfile" {
  orphans=""
  for bat in $(find "$REPO_ROOT" -name 'build.bat' -not -path '*/.git/*' | sort); do
    d="$(dirname "$bat")"
    [ -f "$d/build.sh" ] || orphans="$orphans ${bat#"$REPO_ROOT"/}(no build.sh)"
    [ -f "$d/Dockerfile" ] || orphans="$orphans ${bat#"$REPO_ROOT"/}(no Dockerfile)"
  done
  echo "orphans:$orphans"
  [ -z "$orphans" ]
}

@test "win-3: every example/run-compile.sh has a sibling .bat, and vice versa" {
  missing=""
  n=0
  for sh in $(find "$REPO_ROOT" -name 'run-compile.sh' -not -path '*/.git/*' | sort); do
    n=$((n + 1))
    [ -f "$(dirname "$sh")/run-compile.bat" ] || missing="$missing ${sh#"$REPO_ROOT"/}"
  done
  extra=""
  for bat in $(find "$REPO_ROOT" -name 'run-compile.bat' -not -path '*/.git/*' | sort); do
    [ -f "$(dirname "$bat")/run-compile.sh" ] || extra="$extra ${bat#"$REPO_ROOT"/}"
  done
  echo "examples=$n .sh without .bat:$missing   .bat without .sh:$extra"
  [ "$n" -ge 9 ]
  [ -z "$missing" ]
  [ -z "$extra" ]
}

@test "win-4: the root orchestrator ships both build-all.sh and build-all.bat" {
  [ -f "$REPO_ROOT/build-all.sh" ]
  [ -f "$REPO_ROOT/build-all.bat" ]
}

@test "win-5: every .bat on disk is tracked by git" {
  cd "$REPO_ROOT"
  tracked="$(git ls-files '*.bat' | sort)"
  ondisk="$(bat_files | sed "s|^$REPO_ROOT/||" | sort)"
  echo "tracked:"; echo "$tracked"
  echo "on disk:"; echo "$ondisk"
  [ "$tracked" = "$ondisk" ]
}

# ---------------------------------------------------------------------------
# cmd.exe preamble
# ---------------------------------------------------------------------------

@test "win-6: every .bat starts with @echo off and uses setlocal/endlocal" {
  bad=""
  for f in $(bat_files); do
    rel="${f#"$REPO_ROOT"/}"
    first="$(head -1 "$f")"
    [ "$first" = "@echo off" ] || bad="$bad $rel(first-line='$first')"
    grep -q -i -E '^[[:space:]]*setlocal([[:space:]]|$)' "$f" || bad="$bad $rel(no-setlocal)"
    # endlocal matters: build-all.bat `call`s the per-target wrappers, so a
    # leaked setlocal scope would bleed into the next language's build.
    grep -q -i -E '^[[:space:]]*endlocal([[:space:]]|$)' "$f" || bad="$bad $rel(no-endlocal)"
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

@test "win-7: no .bat contains an interactive pause that would hang CI" {
  bad=""
  for f in $(bat_files); do
    if bat_code "$f" | grep -q -i -E '^[[:space:]]*pause([[:space:]]|$)'; then
      bad="$bad ${f#"$REPO_ROOT"/}"
    fi
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

# ---------------------------------------------------------------------------
# %~dp0: never assume the caller's CWD
# ---------------------------------------------------------------------------

@test "win-8: every .bat resolves its own directory via %~dp0" {
  bad=""
  for f in $(bat_files); do
    grep -q -F -- '%~dp0' "$f" || bad="$bad ${f#"$REPO_ROOT"/}"
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

@test "win-9: every docker/call invocation is anchored on %~dp0, never the CWD" {
  bad=""
  for f in $(bat_files); do
    rel="${f#"$REPO_ROOT"/}"
    out="$(unanchored_invocations "$f")"
    [ -z "$out" ] || bad="$bad|$rel: $out"
    # no CWD-relative navigation at all
    if bat_code "$f" | grep -q -i -E '^[[:space:]]*(cd|chdir|pushd)([[:space:]]|$)'; then
      bad="$bad|$rel: navigates with cd/pushd"
    fi
    if bat_code "$f" | grep -q -F -- '%CD%'; then
      bad="$bad|$rel: reads %CD%"
    fi
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

@test "win-10: no %~dp0\\ double backslash (%~dp0 already ends in one)" {
  bad=""
  for f in $(bat_files); do
    out="$(dp0_double_backslash "$f")"
    [ -z "$out" ] || bad="$bad|${f#"$REPO_ROOT"/}: $out"
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

# ---------------------------------------------------------------------------
# failure propagation (the orch-1 / orch-2 bug, Windows side)
# ---------------------------------------------------------------------------

@test "win-11: every docker/call invocation is followed by 'if errorlevel 1' + 'exit /b 1'" {
  bad=""
  for f in $(bat_files); do
    out="$(unguarded_invocations "$f")"
    [ -z "$out" ] || bad="$bad|${f#"$REPO_ROOT"/}: $out"
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

@test "win-12: the errorlevel check is not vacuous - every .bat really invokes something" {
  bad=""
  for f in $(bat_files); do
    n="$(invocation_count "$f")"
    [ "$n" -ge 1 ] || bad="$bad ${f#"$REPO_ROOT"/}"
  done
  echo "wrappers with no docker/call line:$bad"
  [ -z "$bad" ]
}

@test "win-13: every failure message goes to stderr (1>&2)" {
  bad=""
  for f in $(bat_files); do
    rel="${f#"$REPO_ROOT"/}"
    n_err="$(bat_code "$f" | grep -c -i -E '^[[:space:]]*echo[[:space:]]+ERROR' || true)"
    n_red="$(bat_code "$f" | grep -c -i -E '^[[:space:]]*echo[[:space:]]+ERROR.*1>&2' || true)"
    [ "$n_err" -ge 1 ] || bad="$bad $rel(no-error-message)"
    [ "$n_err" -eq "$n_red" ] || bad="$bad $rel($n_err errors, $n_red on stderr)"
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

# ---------------------------------------------------------------------------
# no drift between the .bat and the .sh it mirrors
# ---------------------------------------------------------------------------

@test "win-14: build.bat builds the same image tag as build.sh, for every target" {
  bad=""
  n=0
  for d in $(target_dirs); do
    rel="${d#"$REPO_ROOT"/}"
    t_sh="$(docker_build_tag "$d/build.sh")"
    t_bat="$(docker_build_tag "$d/build.bat")"
    [ -n "$t_sh" ] || bad="$bad $rel(no tag in build.sh)"
    [ -n "$t_bat" ] || bad="$bad $rel(no tag in build.bat)"
    [ "$t_sh" = "$t_bat" ] || bad="$bad $rel(sh=$t_sh bat=$t_bat)"
    # and it is the tag the CONTRACT mandates, which is the only contract the
    # client repos rely on
    [ "$t_bat" = "ondewo-$rel-proto-compiler:latest" ] || bad="$bad $rel(unexpected tag $t_bat)"
    n=$((n + 1))
  done
  echo "targets=$n offenders:$bad"
  [ "$n" -ge 11 ]
  [ -z "$bad" ]
}

@test "win-15: build-all.bat builds exactly the language list build-all.sh does" {
  list_sh="$(sed -n 's/^for lang in \(.*\); do$/\1/p' "$REPO_ROOT/build-all.sh")"
  list_bat="$(sed -n 's/^for %%L in (\(.*\)) do (.*$/\1/p' "$REPO_ROOT/build-all.bat")"
  echo "sh : [$list_sh]"
  echo "bat: [$list_bat]"
  [ -n "$list_sh" ]
  [ "$list_sh" = "$list_bat" ]
  # and every listed language actually has a build.bat to call
  missing=""
  for lang in $list_bat; do
    [ -f "$REPO_ROOT/$lang/build.bat" ] || missing="$missing $lang"
  done
  echo "listed but missing a build.bat:$missing"
  [ -z "$missing" ]
  # ... and no target is silently skipped by build-all.bat
  unlisted=""
  for d in $(target_dirs); do
    rel="${d#"$REPO_ROOT"/}"
    case " $list_bat " in
      *" $rel "*) ;;
      *) unlisted="$unlisted $rel" ;;
    esac
  done
  echo "targets absent from build-all.bat:$unlisted"
  [ -z "$unlisted" ]
}

@test "win-16: build-all.bat uses 'call' for the sub-wrappers, not a bare invocation" {
  # Without `call`, cmd.exe transfers control to the child batch file and never
  # comes back - only the first language would ever be built.
  refs="$(bat_code "$REPO_ROOT/build-all.bat" | grep -F 'build.bat' || true)"
  echo "references:"; echo "$refs"
  [ -n "$refs" ]
  uncalled="$(printf '%s\n' "$refs" | grep -v -E '^[[:space:]]*call[[:space:]]' || true)"
  echo "not invoked via call:"; echo "$uncalled"
  [ -z "$uncalled" ]
}

@test "win-17: run-compile.bat runs the same image and entrypoint args as run-compile.sh" {
  bad=""
  n=0
  for sh in $(find "$REPO_ROOT" -name 'run-compile.sh' -not -path '*/.git/*' | sort); do
    rel="${sh#"$REPO_ROOT"/}"
    bat="$(dirname "$sh")/run-compile.bat"
    a_sh="$(codegen_run_args "$sh")"
    a_bat="$(codegen_run_args "$bat")"
    [ -n "$a_sh" ] || bad="$bad|$rel: no codegen docker run in the .sh"
    [ "$a_sh" = "$a_bat" ] || bad="$bad|$rel: sh=[$a_sh] bat=[$a_bat]"
    n=$((n + 1))
  done
  echo "examples=$n offenders:$bad"
  [ "$n" -ge 9 ]
  [ -z "$bad" ]
}

# ---------------------------------------------------------------------------
# docker invocation hygiene
# ---------------------------------------------------------------------------

@test "win-18: no codegen 'docker run' in a .bat carries -it" {
  bad=""
  for f in $(bat_files); do
    out="$(tty_codegen_runs "$f")"
    [ -z "$out" ] || bad="$bad|${f#"$REPO_ROOT"/}: $out"
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

@test "win-19: -it survives only on the --entrypoint /bin/bash debug line" {
  # The debug form is allowed to be interactive; assert it is the only place -it
  # appears at all, so the exemption in win-18 cannot be abused.
  bad=""
  for f in $(bat_files); do
    out="$(bat_code "$f" | grep -E '(^|[[:space:]])-it([[:space:]]|$)' | grep -v -F -- '--entrypoint /bin/bash' || true)"
    [ -z "$out" ] || bad="$bad|${f#"$REPO_ROOT"/}: $out"
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

@test "win-20: every -v mount and every docker build context is quoted" {
  # Windows paths routinely contain spaces (C:\Program Files\...); an unquoted
  # mount silently splits into two arguments.
  bad=""
  for f in $(bat_files); do
    rel="${f#"$REPO_ROOT"/}"
    out="$(bat_code "$f" | grep -E '^[[:space:]]*docker[[:space:]]' | grep -E -- '-v [^"]' || true)"
    [ -z "$out" ] || bad="$bad|$rel: unquoted -v: $out"
    ctx="$(bat_code "$f" | grep -E '^[[:space:]]*docker[[:space:]]+build' | grep -v -E -- '-t[[:space:]]+[^[:space:]]+[[:space:]]+"' || true)"
    [ -z "$ctx" ] || bad="$bad|$rel: unquoted build context: $ctx"
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

@test "win-21: every mkdir is guarded by 'if not exist'" {
  # cmd.exe's mkdir sets ERRORLEVEL 1 when the directory already exists, so an
  # unguarded mkdir followed by the win-11 errorlevel check would abort every
  # run after the first.
  bad=""
  n=0
  for f in $(bat_files); do
    rel="${f#"$REPO_ROOT"/}"
    # via a file, not a heredoc: batch paths are full of backslashes and an
    # unquoted heredoc would eat some of them.
    bat_code "$f" | grep -i -E '(^|[[:space:]])mkdir[[:space:]]' > "$SANDBOX/mkdir.txt" || true
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      n=$((n + 1))
      case "$line" in
        *"if not exist "*) ;;
        *) bad="$bad|$rel: $line" ;;
      esac
    done < "$SANDBOX/mkdir.txt"
  done
  echo "mkdir lines=$n offenders:$bad"
  [ "$n" -ge 9 ]
  [ -z "$bad" ]
}

# ---------------------------------------------------------------------------
# encoding / line endings
# ---------------------------------------------------------------------------

@test "win-22: every .bat ends with a trailing newline" {
  bad=""
  for f in $(bat_files); do
    # $(...) strips trailing newlines, so an empty result == the file's last
    # byte is a newline.
    [ -z "$(tail -c 1 "$f")" ] || bad="$bad ${f#"$REPO_ROOT"/}"
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

@test "win-23: no .bat contains a literal CR - the repo keeps LF" {
  cr="$(printf '\r')"
  bad=""
  for f in $(bat_files); do
    if LC_ALL=C grep -q "$cr" "$f"; then
      bad="$bad ${f#"$REPO_ROOT"/}"
    fi
  done
  echo "offenders:$bad"
  [ -z "$bad" ]
}

@test "win-24: every .bat is pure ASCII (cmd.exe's code page mangles the sh banners' emoji)" {
  bad=""
  for f in $(bat_files); do
    left="$(LC_ALL=C tr -d '\000-\177' < "$f")"
    [ -z "$left" ] || bad="$bad ${f#"$REPO_ROOT"/}"
  done
  echo "offenders (non-ASCII bytes):$bad"
  [ -z "$bad" ]
  # the .bat banners say [OK] where the .sh banners say the check mark
  grep -q -F '[OK]' "$REPO_ROOT/build-all.bat"
}

# ---------------------------------------------------------------------------
# negative controls: prove the detectors above actually detect
# ---------------------------------------------------------------------------

@test "win-25: unguarded_invocations flags a wrapper that swallows a failed docker build" {
  cat > "$SANDBOX/bad.bat" <<'EOF'
@echo off
setlocal
docker build --no-cache -t ondewo-x-proto-compiler:latest "%~dp0."
echo [OK] Done
endlocal
EOF
  out="$(unguarded_invocations "$SANDBOX/bad.bat")"
  echo "detector said: $out"
  [ -n "$out" ]

  cat > "$SANDBOX/good.bat" <<'EOF'
@echo off
setlocal
docker build --no-cache -t ondewo-x-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: x: docker build failed 1>&2
    exit /b 1
)
endlocal
EOF
  out="$(unguarded_invocations "$SANDBOX/good.bat")"
  echo "detector said: $out"
  [ -z "$out" ]
}

@test "win-26: unguarded_invocations flags a guard that logs but does not exit non-zero" {
  cat > "$SANDBOX/bad.bat" <<'EOF'
@echo off
setlocal
docker build --no-cache -t ondewo-x-proto-compiler:latest "%~dp0."
if errorlevel 1 (
    echo ERROR: x: docker build failed 1>&2
)
endlocal
EOF
  out="$(unguarded_invocations "$SANDBOX/bad.bat")"
  echo "detector said: $out"
  [ -n "$out" ]
}

@test "win-27: unguarded_invocations flags a second invocation that is never checked" {
  cat > "$SANDBOX/bad.bat" <<'EOF'
@echo off
setlocal
call "%~dp0a\build.bat"
call "%~dp0b\build.bat"
if errorlevel 1 (
    echo ERROR: build failed 1>&2
    exit /b 1
)
endlocal
EOF
  out="$(unguarded_invocations "$SANDBOX/bad.bat")"
  echo "detector said: $out"
  [ -n "$out" ]
}

@test "win-28: tty_codegen_runs flags -it on a codegen run but not on the debug line" {
  cat > "$SANDBOX/bad.bat" <<'EOF'
@echo off
setlocal
docker run -it -v "%~dp0.":/input-volume ondewo-x-proto-compiler protos
endlocal
EOF
  out="$(tty_codegen_runs "$SANDBOX/bad.bat")"
  echo "detector said: $out"
  [ -n "$out" ]

  cat > "$SANDBOX/good.bat" <<'EOF'
@echo off
setlocal
docker run -it --entrypoint /bin/bash -v "%~dp0.":/input-volume ondewo-x-proto-compiler
endlocal
EOF
  out="$(tty_codegen_runs "$SANDBOX/good.bat")"
  echo "detector said: $out"
  [ -z "$out" ]
}

@test "win-29: unanchored_invocations flags a wrapper that builds from the caller's CWD" {
  cat > "$SANDBOX/bad.bat" <<'EOF'
@echo off
setlocal
docker build --no-cache -t ondewo-x-proto-compiler:latest .
endlocal
EOF
  out="$(unanchored_invocations "$SANDBOX/bad.bat")"
  echo "detector said: $out"
  [ -n "$out" ]

  cat > "$SANDBOX/good.bat" <<'EOF'
@echo off
setlocal
set "FILEDIRECTORY=%~dp0"
docker run -v "%FILEDIRECTORY%.":/input-volume ondewo-x-proto-compiler protos
endlocal
EOF
  out="$(unanchored_invocations "$SANDBOX/good.bat")"
  echo "detector said: $out"
  [ -z "$out" ]
}

@test "win-30: dp0_double_backslash flags %~dp0\\ and an unstripped %VAR%\\" {
  cat > "$SANDBOX/literal.bat" <<'EOF'
@echo off
setlocal
docker run -v "%~dp0\lib":/output-volume ondewo-x-proto-compiler protos
endlocal
EOF
  out="$(dp0_double_backslash "$SANDBOX/literal.bat")"
  echo "detector said: $out"
  [ -n "$out" ]

  cat > "$SANDBOX/viavar.bat" <<'EOF'
@echo off
setlocal
set "FILEDIRECTORY=%~dp0"
docker run -v "%FILEDIRECTORY%\lib":/output-volume ondewo-x-proto-compiler protos
endlocal
EOF
  out="$(dp0_double_backslash "$SANDBOX/viavar.bat")"
  echo "detector said: $out"
  [ -n "$out" ]

  cat > "$SANDBOX/stripped.bat" <<'EOF'
@echo off
setlocal
set "FILEDIRECTORY=%~dp0"
set "FILEDIRECTORY=%FILEDIRECTORY:~0,-1%"
docker run -v "%FILEDIRECTORY%\lib":/output-volume ondewo-x-proto-compiler protos
endlocal
EOF
  out="$(dp0_double_backslash "$SANDBOX/stripped.bat")"
  echo "detector said: $out"
  [ -z "$out" ]
}
