#!/bin/bash
set -e

# -------------- Pre-warm the maven local repository (BUILD TIME ONLY)
# This is the only networked step of the java toolchain. It packages a seed project whose
# pom.xml is produced by the very same make-lib-entry-point.sh from the very same template, so
# the seed's dependency and plugin coordinates are identical to those of any real generation
# run. Packaging it downloads every artifact the lifecycle touches into $MAVEN_REPO_LOCAL.
#
# `mvn dependency:go-offline` is deliberately NOT used: it is long documented to miss plugin
# dependencies resolved during the lifecycle, which would leave an incomplete repository that
# only ever fails on a customer's machine.

echo "---------------------------------------------------------------"
echo "Java: Starting maven local repository pre-warming ..."
echo "---------------------------------------------------------------"

#Container defaults; env-overridable so the script can run (and be tested) outside the image
IMAGE_DATA_DIRECTORY="${IMAGE_DATA_DIRECTORY:-/image-data}"
DEFAULT_FILES_DIR=$IMAGE_DATA_DIRECTORY/default-lib-files
MAVEN_REPO_LOCAL="${MAVEN_REPO_LOCAL:-$IMAGE_DATA_DIRECTORY/.m2/repository}"
PROTOC_GEN_GRPC_JAVA="${PROTOC_GEN_GRPC_JAVA:-/usr/local/bin/protoc-gen-grpc-java}"

if [ ! -f "$DEFAULT_FILES_DIR/seed.proto" ]; then
    echo "ERROR: the seed proto '$DEFAULT_FILES_DIR/seed.proto' does not exist - exiting" >&2
    exit 1
fi

#mktemp always with an XXXXXX template (portable across GNU and BSD)
SEED_DIR=$(mktemp -d "${TMPDIR:-/tmp}/maven-seed.XXXXXX")
#Single-quoted so $SEED_DIR is expanded when the trap fires, not when it is installed; `${VAR:?}`
#like every other rm -rf in the repo, so an unset value aborts the cleanup instead of widening it
trap 'rm -rf "${SEED_DIR:?}"' EXIT

mkdir -p "$SEED_DIR/src/main/java" "$MAVEN_REPO_LOCAL"

# Generating the seed proto here smoke-tests protoc AND the grpc-java plugin at image BUILD
# time (a broken or truncated plugin download fails `docker build`, not the first customer
# run), and gives the warm-up build a real generated source tree, so it exercises exactly the
# compile classpath a customer run will.
echo "Generating the seed stubs to smoke-test protoc and the grpc-java plugin"
protoc \
    --plugin=protoc-gen-grpc-java="$PROTOC_GEN_GRPC_JAVA" \
    --java_out="$SEED_DIR/src/main/java" \
    --grpc-java_out="$SEED_DIR/src/main/java" \
    -I "$DEFAULT_FILES_DIR" \
    "$DEFAULT_FILES_DIR/seed.proto"

bash "$IMAGE_DATA_DIRECTORY/make-lib-entry-point.sh" "$SEED_DIR" com.ondewo ondewo-seed 0.0.0

# ONLINE on purpose. NOTE: the goal list here MUST be a superset of every goal any later
# offline invocation uses. `clean` is not part of the default (jar) lifecycle, so a
# `package`-only warm-up never downloads maven-clean-plugin and the --offline verification
# below then fails with "Cannot access central ... in offline mode".
echo "Downloading every dependency and lifecycle plugin into $MAVEN_REPO_LOCAL"
mvn --batch-mode \
    -f "$SEED_DIR/pom.xml" \
    -Dmaven.repo.local="$MAVEN_REPO_LOCAL" \
    -Dmaven.test.skip=true \
    clean package

# The online pass leaves per-artifact remote-repository bookkeeping behind, which can make a
# later offline resolution reject an artifact that is physically present. Drop it.
echo "Removing the remote-repository bookkeeping that would break offline resolution"
find "$MAVEN_REPO_LOCAL" -name "_remote.repositories" -delete
find "$MAVEN_REPO_LOCAL" -name "*.lastUpdated" -delete
find "$MAVEN_REPO_LOCAL" -name "resolver-status.properties" -delete

# Proof, at image build time, that a generation run needs no network: the very same build must
# now pass with --offline. If anything is missing, `docker build` fails here instead of on a
# customer's machine - the no-network guarantee is proven, not asserted in a comment.
echo "Verifying the pre-warmed repository by re-running the identical build with --offline"
mvn --batch-mode --offline \
    -f "$SEED_DIR/pom.xml" \
    -Dmaven.repo.local="$MAVEN_REPO_LOCAL" \
    -Dmaven.test.skip=true \
    clean package

echo "---------------------------------------------------------------"
echo "✅ Java: Done maven local repository pre-warming"
echo "---------------------------------------------------------------"
