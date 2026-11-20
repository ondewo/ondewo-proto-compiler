#!/bin/sh
# Fails when a toolchain pin disagrees between the Makefile and the files it is meant to govern.
# Usage: check-version-pins.sh [<repo_root>]   (default: the repository this script lives in)
#
# Two kinds of pins are checked against the Makefile variables:
#   * Dockerfile ARG defaults. The release target rewrites them from DOCKERFILE_ARGS, but nothing
#     stopped a hand edit of one Dockerfile (or of the Makefile) from drifting until then, and an
#     image is built from its Dockerfile, not from the Makefile.
#   * Hand-maintained manifests that no release target rewrites: python/requirements.txt, the rust
#     Cargo.toml files, the go module template and the node package.json files.
# Plus the one-protobuf-release rule: every runtime that has a per-protoc release line (java,
# csharp, php, python) is on the line of PROTOC_VERSION.
#
# Prints one line per mismatch and exits 1 if there is any; jq is required.
set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
MAKEFILE="$ROOT/Makefile"
FAILED=0

fail() {
  printf 'MISMATCH: %s\n' "$*"
  FAILED=1
}

# mk <NAME>: the value of a top-level NAME=VALUE line of the Makefile (empty when missing)
mk() {
  sed -n "s|^$1=||p" "$MAKEFILE" | head -n 1
}


# expect <file> <what> <actual> <expected>
expect() {
  [ "$3" = "$4" ] || fail "$1: $2 is '$3', the Makefile says '$4'"
}

# json <file> <jq path>: a string out of a package.json ('' when absent)
json() {
  jq -r "$2 // \"\"" "$ROOT/$1"
}

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 2; }
[ -f "$MAKEFILE" ] || { echo "ERROR: no Makefile at $MAKEFILE" >&2; exit 2; }

# The pins of the hand-maintained manifests have no Dockerfile ARG; the Makefile carries them only
# so that this check has one place to compare against. A missing one is a mismatch of its own.
for name in PROTOC_VERSION GRPC_WEB_VERSION PROTOC_GEN_JS_VERSION WEBPACK_VERSION WEBPACK_CLI_VERSION \
  PYTHON_GRPCIO_VERSION PYTHON_PROTOBUF_VERSION PYTHON_MYPY_PROTOBUF_VERSION PROST_VERSION TONIC_VERSION \
  GO_MOD_DIRECTIVE GRPC_GO_VERSION PROTOC_GEN_GO_VERSION GENPROTO_VERSION NGX_GRPC_VERSION \
  ANGULAR_GOOGLE_PROTOBUF_VERSION NODEJS_GRPC_TOOLS_VERSION NODEJS_PROTOC_GEN_JS_VERSION \
  NODEJS_GRPC_JS_VERSION NODEJS_GOOGLE_PROTOBUF_VERSION PROTOBUF_JAVA_VERSION GOOGLE_PROTOBUF_VERSION \
  GOOGLE_PROTOBUF_PHP_VERSION; do
  [ -n "$(mk "$name")" ] || fail "Makefile: $name is not set"
done

# ------------------------------------------------------------------ Dockerfile ARG defaults
# Every NAME of DOCKERFILE_ARGS whose value is a plain Makefile variable. LIB_VERSION and
# ONDEWO_PROTO_COMPILER_VERSION are the release version, which the release target itself
# propagates when it cuts the release; they are deliberately not a toolchain pin.
ARG_NAMES=$(awk '/^DOCKERFILE_ARGS[[:space:]]*=/ { inblk = 1 }
                 inblk { print; if ($0 !~ /\\[[:space:]]*$/) exit }' "$MAKEFILE" |
  sed -n 's|^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)=\${\1}.*|\1|p' |
  grep -v '^ONDEWO_PROTO_COMPILER_VERSION$' || true)
[ -n "$ARG_NAMES" ] || fail "Makefile: no NAME=\${NAME} pair found in DOCKERFILE_ARGS"

for dockerfile in "$ROOT"/*/Dockerfile "$ROOT"/Dockerfile.utils; do
  [ -f "$dockerfile" ] || continue
  rel=${dockerfile#"$ROOT"/}
  for name in $ARG_NAMES; do
    sed -n "s|^ARG $name=||p" "$dockerfile" | while IFS= read -r value; do
      want=$(mk "$name")
      [ "$value" = "$want" ] || printf 'MISMATCH: %s: ARG %s=%s, the Makefile says %s\n' "$rel" "$name" "$value" "$want"
    done
  done
done > "${TMPDIR:-/tmp}/check-version-pins.$$"
if [ -s "${TMPDIR:-/tmp}/check-version-pins.$$" ]; then
  cat "${TMPDIR:-/tmp}/check-version-pins.$$"
  FAILED=1
fi
rm -f "${TMPDIR:-/tmp}/check-version-pins.$$"

# ------------------------------------------------------------------ python/requirements.txt
REQ=python/requirements.txt
# req <package>: the exact version of a `package==version` line ('' when not pinned exactly)
req() {
  sed -n "s|^$1==\([^[:space:]#]*\).*|\1|p" "$ROOT/$REQ" | head -n 1
}
grpcio=$(mk PYTHON_GRPCIO_VERSION)
for pkg in grpcio grpcio-reflection grpcio-status grpcio-tools; do
  expect "$REQ" "$pkg" "$(req "$pkg")" "$grpcio"
done
expect "$REQ" protobuf "$(req protobuf)" "$(mk PYTHON_PROTOBUF_VERSION)"
expect "$REQ" mypy-protobuf "$(req mypy-protobuf)" "$(mk PYTHON_MYPY_PROTOBUF_VERSION)"

# ------------------------------------------------------------------ rust crate manifests
prost=$(mk PROST_VERSION)
tonic=$(mk TONIC_VERSION)
for toml in rust/image-data/default-lib-files/Cargo.toml rust/image-data/default-lib-files/prewarm-Cargo.toml; do
  # crate <name>: the version of `name = "x"` or `name = { version = "x", ... }`
  crate() {
    sed -n -e "s|^$1 = \"\([^\"]*\)\".*|\1|p" -e "s|^$1 = { *version = \"\([^\"]*\)\".*|\1|p" "$ROOT/$toml" | head -n 1
  }
  expect "$toml" prost "$(crate prost)" "$prost"
  expect "$toml" prost-types "$(crate prost-types)" "$prost"
  expect "$toml" tonic "$(crate tonic)" "$tonic"
  expect "$toml" tonic-prost "$(crate tonic-prost)" "$tonic"
done

# ------------------------------------------------------------------ go module template
GOMOD=go/image-data/default-lib-files/go.mod.template
gomod() {
  sed -n "s|^[[:space:]]*$1[[:space:]][[:space:]]*\([^[:space:]]*\).*|\1|p" "$ROOT/$GOMOD" | head -n 1
}
expect "$GOMOD" "go directive" "$(sed -n 's|^go ||p' "$ROOT/$GOMOD")" "$(mk GO_MOD_DIRECTIVE)"
expect "$GOMOD" google.golang.org/grpc "$(gomod 'google\.golang\.org/grpc')" "v$(mk GRPC_GO_VERSION)"
expect "$GOMOD" google.golang.org/protobuf "$(gomod 'google\.golang\.org/protobuf')" "v$(mk PROTOC_GEN_GO_VERSION)"
for mod in genproto genproto/googleapis/api genproto/googleapis/rpc; do
  expect "$GOMOD" "google.golang.org/$mod" "$(gomod "google\.golang\.org/$mod")" "$(mk GENPROTO_VERSION)"
done

# ------------------------------------------------------------------ node package.json files
grpc_web=$(mk GRPC_WEB_VERSION)
gen_js=$(mk PROTOC_GEN_JS_VERSION)
PKG=js/image-data/default-lib-files/package.json
expect "$PKG" grpc-web "$(json "$PKG" '.dependencies["grpc-web"]')" "^$grpc_web"
# protoc-gen-js N.x generates code for the google-protobuf release line N.x
expect "$PKG" google-protobuf "$(json "$PKG" '.dependencies["google-protobuf"]')" "^$gen_js"
expect "$PKG" webpack "$(json "$PKG" '.devDependencies.webpack')" "^$(mk WEBPACK_VERSION)"
expect "$PKG" webpack-cli "$(json "$PKG" '.devDependencies["webpack-cli"]')" "^$(mk WEBPACK_CLI_VERSION)"
PKG=typescript/example/package.json
expect "$PKG" grpc-web "$(json "$PKG" '.dependencies["grpc-web"]')" "^$grpc_web"
expect "$PKG" google-protobuf "$(json "$PKG" '.dependencies["google-protobuf"]')" "^$gen_js"

PKG=angular/image-data/package.json
ngx=$(mk NGX_GRPC_VERSION)
for name in common core grpc-web-client protoc-gen-ng well-known-types; do
  expect "$PKG" "@ngx-grpc/$name" "$(json "$PKG" ".devDependencies[\"@ngx-grpc/$name\"]")" ">=$ngx"
done
expect "$PKG" grpc-web "$(json "$PKG" '.devDependencies["grpc-web"]')" "$grpc_web"
expect "$PKG" "overrides.grpc-web" "$(json "$PKG" '.overrides["grpc-web"]')" '$grpc-web'
expect "$PKG" google-protobuf "$(json "$PKG" '.devDependencies["google-protobuf"]')" "~$(mk ANGULAR_GOOGLE_PROTOBUF_VERSION)"

PKG=nodejs/image-data/package.json
expect "$PKG" grpc-tools "$(json "$PKG" '.devDependencies["grpc-tools"]')" "$(mk NODEJS_GRPC_TOOLS_VERSION)"
expect "$PKG" protoc-gen-js "$(json "$PKG" '.devDependencies["protoc-gen-js"]')" "$(mk NODEJS_PROTOC_GEN_JS_VERSION)"
for PKG in nodejs/image-data/package.json nodejs/example/package.json; do
  section=devDependencies
  [ "$PKG" = nodejs/example/package.json ] && section=dependencies
  expect "$PKG" @grpc/grpc-js "$(json "$PKG" ".${section}[\"@grpc/grpc-js\"]")" "^$(mk NODEJS_GRPC_JS_VERSION)"
  expect "$PKG" google-protobuf "$(json "$PKG" ".${section}[\"google-protobuf\"]")" "$(mk NODEJS_GOOGLE_PROTOBUF_VERSION)"
done

# ------------------------------------------------------------------ one protobuf release for all
# protoc <major>.<minor> ships the runtimes java 4.<major>.x, csharp 3.<major>.x, php 5.<major>.x
# (5.x from protoc 34 on) and python 7.<major>.x (6.x for protoc 30-33); a runtime may be NEWER
# than the gencode, so python only has to be at least on the protoc line.
protoc_major=$(mk PROTOC_VERSION | cut -d. -f1)
line() { printf '%s' "$1" | cut -d. -f1-2; }
expect Makefile "PROTOBUF_JAVA_VERSION line" "$(line "$(mk PROTOBUF_JAVA_VERSION)")" "4.$protoc_major"
expect Makefile "GOOGLE_PROTOBUF_VERSION (csharp) line" "$(line "$(mk GOOGLE_PROTOBUF_VERSION)")" "3.$protoc_major"
expect Makefile "GOOGLE_PROTOBUF_PHP_VERSION line" "$(line "$(mk GOOGLE_PROTOBUF_PHP_VERSION)")" "5.$protoc_major"
python_minor=$(mk PYTHON_PROTOBUF_VERSION | cut -d. -f2)
case "$python_minor" in ''|*[!0-9]*) python_minor=0 ;; esac
[ "$python_minor" -ge "${protoc_major:-0}" ] ||
  fail "Makefile: PYTHON_PROTOBUF_VERSION $(mk PYTHON_PROTOBUF_VERSION) is older than the gencode of protoc $(mk PROTOC_VERSION)"

if [ "$FAILED" -ne 0 ]; then
  echo "❌ version pins disagree with the Makefile"
  exit 1
fi
echo "✅ every version pin agrees with the Makefile"
