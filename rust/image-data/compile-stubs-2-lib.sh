#!/bin/bash
set -e

# ---------------------------------------------------------------------------------------
# The real package build of the rust pipeline - the analogue of angular's `npm run build`
# and js's webpack run.
#
#   compile-stubs-2-lib.sh <crate_dir> <dist_dir>
#
# `cargo build --release` is what proves the generated code actually COMPILES (a codegen
# regression fails the container instead of shipping a broken crate); `cargo package` then
# produces the distributable <name>-<version>.crate tarball, which is collected in
# <dist_dir> for the orchestrator's copy-back.
#
# Both reuse the dependencies prebuilt into CARGO_TARGET_DIR at image-build time, so run
# time only compiles the generated crate itself - and only offline.
# ---------------------------------------------------------------------------------------

#Root directory of the assembled crate (-> Cargo.toml + src/lib.rs + src/api)
CRATE_DIRECTORY=$1
#Where the packaged *.crate artifact is collected
DIST_DIRECTORY=$2

#Container defaults; env-overridable so the script can run (and be tested) outside the image
IMAGE_DATA_DIRECTORY="${IMAGE_DATA_DIRECTORY:-/image-data}"

#External binaries, env-overridable so the script stays drivable outside the image
CARGO="${CARGO:-cargo}"

#Where `cargo install`/the pre-warm layer left the downloaded .crate files. Deliberately a
#repo-owned knob rather than the AMBIENT CARGO_HOME: the image's own ENV CARGO_HOME is
#/usr/local/cargo, so the container behaviour is byte-identical, while a developer's or CI
#runner's populated ~/.cargo can no longer decide what the pre-flight below sees.
CARGO_REGISTRY_HOME="${CARGO_REGISTRY_HOME:-/usr/local/cargo}"
#Lockfile resolved at image-build time from the pre-warm manifest
PREWARM_LOCK="$IMAGE_DATA_DIRECTORY/prewarm/Cargo.lock"

if [ -z "$CRATE_DIRECTORY" ] || [ -z "$DIST_DIRECTORY" ]; then
    echo "ERROR: usage: compile-stubs-2-lib.sh <crate_dir> <dist_dir> - exiting" >&2
    exit 1
fi
if [ ! -f "$CRATE_DIRECTORY/Cargo.toml" ]; then
    echo "ERROR: no Cargo.toml in the crate directory '$CRATE_DIRECTORY' - the protoc gen_crate step did not run - exiting" >&2
    exit 1
fi
if [ ! -f "$CRATE_DIRECTORY/src/lib.rs" ]; then
    echo "ERROR: no src/lib.rs in the crate directory '$CRATE_DIRECTORY' - the crate has no entry point - exiting" >&2
    exit 1
fi

echo "---------------------------------------------------------------"
echo "Starting rust build process of library package ..."
echo "---------------------------------------------------------------"

# -------------- Escape hatch: generate the stubs without compiling them. Lets a manifest
# change that outruns the image's warmed cache still produce usable stubs instead of
# blocking codegen entirely. It has to be evaluated BEFORE the offline dependency pre-flight
# below - a pre-flight failure is the single failure this hatch exists to escape, so running
# it first would leave the escape hatch unable to escape anything.
if [ "${SKIP_CARGO_BUILD:-0}" = "1" ]; then
    echo "SKIP_CARGO_BUILD=1 -> skipping the cargo build/package step (stub generation only)"
    echo "Finished rust build."
    exit 0
fi

# CARGO_TARGET_DIR is an AMBIENT cargo variable (many developers export a shared one), so it
# is deliberately derived from the repo-owned IMAGE_DATA_DIRECTORY knob instead of being
# honoured from the environment: letting a stray value win would build outside the image and
# make the *.crate lookup below pick up a foreign artifact. The Dockerfile's ENV only has to
# agree with this. It must be absolute - cargo resolves a relative one against its own CWD.
CARGO_TARGET_DIR="$IMAGE_DATA_DIRECTORY/cargo-target"
mkdir -p "$CARGO_TARGET_DIR"
CARGO_TARGET_DIR="$(cd "$CARGO_TARGET_DIR" && pwd)"
export CARGO_TARGET_DIR

#Resolve the dist dir to an absolute path before the cd below
mkdir -p "$DIST_DIRECTORY"
DIST_DIRECTORY="$(cd "$DIST_DIRECTORY" && pwd)"

# -------------- Seed the lockfile resolved at image-build time so the offline build is
# deterministic and the shipped crate carries a lockfile. Cargo re-resolves only the root
# package when the client supplied a manifest with a different name - no network needed.
if [ ! -f "$CRATE_DIRECTORY/Cargo.lock" ] && [ -f "$PREWARM_LOCK" ]; then
    echo "No Cargo.lock in the crate -> seeding the pre-warmed lockfile from '$PREWARM_LOCK'"
    cp "$PREWARM_LOCK" "$CRATE_DIRECTORY/Cargo.lock" || { echo "ERROR: failed to seed the pre-warmed Cargo.lock" >&2; exit 1; }
fi

# -------------- Pre-flight: every dependency must already be in the image's warmed cargo
# cache. The image bakes CARGO_NET_OFFLINE=true and the build below passes --offline, so a
# dependency the pre-warm layer never downloaded cannot be fetched - it would fail deep
# inside cargo's resolver with an opaque "can't be used because it requires internet access".
# Catch it here with a message that says exactly what to do about it.
REGISTRY_CACHE="$CARGO_REGISTRY_HOME/registry/cache"
if [ -d "$REGISTRY_CACHE" ]; then
    #Every `<name> = ...` key of the [dependencies] table (the sed range ends at the next
    #section header, whose own "[" line cannot match the name pattern).
    CRATE_DEPENDENCIES=$(sed -n '/^\[dependencies\]/,/^\[/p' "$CRATE_DIRECTORY/Cargo.toml" \
        | sed -n 's|^\([A-Za-z0-9_-][A-Za-z0-9_-]*\)[[:space:]]*=.*|\1|p')
    #A dependency may equally be written as its own TOML sub-table - `[dependencies.tokio]`
    #followed by `version = ...` / `features = ...` - which the inline-key pass above cannot
    #see. Collect those names too, or a feature-heavy client dependency sails past the
    #pre-flight straight into the opaque offline resolver error this check exists to prevent.
    CRATE_DEPENDENCIES="$CRATE_DEPENDENCIES $(sed -n 's|^\[dependencies\.\([A-Za-z0-9_-][A-Za-z0-9_-]*\)\].*|\1|p' "$CRATE_DIRECTORY/Cargo.toml")"
    # shellcheck disable=SC2086  # intentional word splitting of the dependency name list
    for dependency in $CRATE_DEPENDENCIES; do
        #"-[0-9]*" and not "-*": a cached prost-types-0.14.4.crate must not be mistaken
        #for the crate "prost" - a crate version always starts with a digit.
        if ! find "$REGISTRY_CACHE" -type f -name "$dependency-[0-9]*.crate" | grep -q .; then
            echo "ERROR: dependency '$dependency' is not in the image's pre-warmed cargo cache." >&2
            echo "       Generation runs fully offline, so it can never be downloaded at run time." >&2
            echo "       Rebuild ondewo-rust-proto-compiler with '$dependency' added to" >&2
            echo "       image-data/default-lib-files/prewarm-Cargo.toml (a changed VERSION" >&2
            echo "       requirement of an already cached dependency needs the same rebuild)," >&2
            echo "       or re-run with SKIP_CARGO_BUILD=1 to emit the stubs uncompiled - exiting" >&2
            exit 1
        fi
    done
else
    echo "WARN: no cargo registry cache at '$REGISTRY_CACHE' -> skipping the offline dependency pre-flight" >&2
fi

cd "$CRATE_DIRECTORY" || exit 1

echo "Executing cargo build (release, offline)"
"$CARGO" build --release --offline || { echo "ERROR: 'cargo build' failed - the generated crate does not compile" >&2; exit 1; }

# --no-verify: the crate was just built, re-building it from the packaged tarball only
# doubles the run time. --allow-dirty is a no-op outside a VCS repo and only guards the
# case where someone mounts a git working tree.
echo "Executing cargo package (offline)"
"$CARGO" package --offline --no-verify --allow-dirty || { echo "ERROR: 'cargo package' failed" >&2; exit 1; }

if [ ! -d "$CARGO_TARGET_DIR/package" ]; then
    echo "ERROR: 'cargo package' created no package directory in '$CARGO_TARGET_DIR' - exiting" >&2
    exit 1
fi
CRATE_ARTIFACT=$(find "$CARGO_TARGET_DIR/package" -maxdepth 1 -type f -name "*.crate" | head -n 1)
if [ -z "$CRATE_ARTIFACT" ]; then
    echo "ERROR: 'cargo package' produced no .crate artifact in '$CARGO_TARGET_DIR/package' - exiting" >&2
    exit 1
fi

echo "Collecting the packaged crate: $CRATE_ARTIFACT"
cp "$CRATE_ARTIFACT" "$DIST_DIRECTORY"/ || { echo "ERROR: failed to copy '$CRATE_ARTIFACT' to '$DIST_DIRECTORY'" >&2; exit 1; }

echo "---------------------------------------------------------------"
echo "✅ Finished rust build."
echo "---------------------------------------------------------------"
