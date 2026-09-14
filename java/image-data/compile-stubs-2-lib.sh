#!/bin/bash
set -e

# -------------- Compile + package the generated stubs into a real maven artifact
# $1 maven project directory: holds the rendered pom.xml and src/main/java/<generated stubs>
MAVEN_PROJECT_DIR=$1

if [ -z "$MAVEN_PROJECT_DIR" ] || [ ! -f "$MAVEN_PROJECT_DIR/pom.xml" ]; then
    echo "ERROR: no pom.xml at '$MAVEN_PROJECT_DIR' - exiting" >&2
    exit 1
fi

#Container defaults; env-overridable so the script can run (and be tested) outside the image.
#MAVEN_REPO_LOCAL is derived from IMAGE_DATA_DIRECTORY (and NOT baked into the image as an ENV
#literal) so redirecting that one knob moves every container path together.
IMAGE_DATA_DIRECTORY="${IMAGE_DATA_DIRECTORY:-/image-data}"
MAVEN_REPO_LOCAL="${MAVEN_REPO_LOCAL:-$IMAGE_DATA_DIRECTORY/.m2/repository}"

echo "---------------------------------------------------------------"
echo "Java: Starting maven build of the client stubs library ..."
echo "---------------------------------------------------------------"

# --offline is deliberate: every dependency and lifecycle plugin was downloaded into
# $MAVEN_REPO_LOCAL while the image was built, so a generation run needs NO network. A missing
# artifact therefore fails loudly here instead of silently dialling out to Maven Central.
# -Dmaven.repo.local is passed explicitly rather than relying on $MAVEN_CONFIG / $HOME, so the
# repository location is identical at image-build time and run time, and independent of which
# user the container runs as.
# -Dmaven.test.skip=true skips test compilation AND execution (there are no tests), so no
# test-scoped artifact has to be pre-warmed.
mvn --batch-mode --offline \
    -f "$MAVEN_PROJECT_DIR/pom.xml" \
    -Dmaven.repo.local="$MAVEN_REPO_LOCAL" \
    -Dmaven.test.skip=true \
    package

# -------------- Assemble the shippable tree (the java analogue of the node targets' lib/)
LIB_DIRECTORY=$MAVEN_PROJECT_DIR/lib
#`${VAR:?}` like every other rm -rf in the repo: an unset/empty $MAVEN_PROJECT_DIR would make
#this `rm -rf /lib` instead of aborting
rm -rf "${LIB_DIRECTORY:?}"
mkdir -p "$LIB_DIRECTORY/src/main/java" "$LIB_DIRECTORY/target"

echo "Copying generated sources and the build descriptor into $LIB_DIRECTORY"
cp -r "$MAVEN_PROJECT_DIR"/src/main/java/* "$LIB_DIRECTORY/src/main/java"
cp "$MAVEN_PROJECT_DIR/pom.xml" "$LIB_DIRECTORY/pom.xml"

# An `if`, not `[ -f … ] && cp …`: under set -e a false `&&` chain in non-final position
# aborts the whole script.
if [ -f "$MAVEN_PROJECT_DIR/LICENSE" ]; then
    cp "$MAVEN_PROJECT_DIR/LICENSE" "$LIB_DIRECTORY/LICENSE"
fi

# Ship the built artifacts only - not the whole target/ scratch tree (classes/, maven-status/,
# generated-sources/ …), which would balloon the output volume and is rebuildable anyway.
if [ ! -d "$MAVEN_PROJECT_DIR/target" ]; then
    echo "ERROR: the maven build produced no '$MAVEN_PROJECT_DIR/target' directory - exiting" >&2
    exit 1
fi
JAR_CNT=$(find "$MAVEN_PROJECT_DIR/target" -maxdepth 1 -name "*.jar" | grep -c . || true)
if [ "$JAR_CNT" -lt 1 ]; then
    echo "ERROR: the maven build produced no .jar in '$MAVEN_PROJECT_DIR/target' - exiting" >&2
    exit 1
fi
find "$MAVEN_PROJECT_DIR/target" -maxdepth 1 -name "*.jar" -exec cp {} "$LIB_DIRECTORY/target" \;
echo "Packaged $JAR_CNT jar file(s) into $LIB_DIRECTORY/target"

echo "---------------------------------------------------------------"
echo "✅ Java: Done maven build of the client stubs library"
echo "---------------------------------------------------------------"
