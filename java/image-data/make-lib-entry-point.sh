#!/bin/bash
set -e

# -------------- Render the maven build descriptor (pom.xml) of the generated library
# Java has no package.json inside the input volume to read the library identity from, so the
# maven coordinates are passed in as arguments, and every toolchain version is taken from the
# image ENV (set from the Dockerfile ARGs). That indirection is deliberate: the pom can then
# never name a dependency or plugin version that is missing from the pre-warmed offline maven
# repository, because both are pinned by the same ARG.
#
# $1 maven project directory the pom.xml is written into
# $2 maven <groupId>
# $3 maven <artifactId>
# $4 maven <version>
MAVEN_PROJECT_DIR=$1
MAVEN_GROUP_ID=$2
MAVEN_ARTIFACT_ID=$3
LIBRARY_VERSION=$4

if [ -z "$MAVEN_PROJECT_DIR" ]; then
    echo "ERROR: usage: make-lib-entry-point.sh <maven_project_dir> <group_id> <artifact_id> <version> - exiting" >&2
    exit 1
fi
if [ -z "$MAVEN_GROUP_ID" ] || [ -z "$MAVEN_ARTIFACT_ID" ] || [ -z "$LIBRARY_VERSION" ]; then
    echo "ERROR: the maven coordinates are incomplete (groupId='$MAVEN_GROUP_ID'," >&2
    echo "       artifactId='$MAVEN_ARTIFACT_ID', version='$LIBRARY_VERSION') - exiting" >&2
    exit 1
fi

#Container defaults; env-overridable so the script can run (and be tested) outside the image
IMAGE_DATA_DIRECTORY="${IMAGE_DATA_DIRECTORY:-/image-data}"
DEFAULT_FILES_DIR=$IMAGE_DATA_DIRECTORY/default-lib-files
POM_TEMPLATE=$DEFAULT_FILES_DIR/pom.xml
POM_FILE=$MAVEN_PROJECT_DIR/pom.xml

mkdir -p "$MAVEN_PROJECT_DIR"

# A pom.xml carried in from the mounted input volume wins over the default template - but the
# package build runs --offline, so anything it names that was not pre-warmed into the image
# fails the build. Warn loudly rather than silently producing a surprising failure later.
if [ -f "$POM_FILE" ]; then
    echo "WARNING: a pom.xml was supplied for '$MAVEN_PROJECT_DIR' -> keeping it instead of the default template."
    echo "WARNING: the maven build runs with --offline, so every dependency and plugin version it"
    echo "WARNING: names must be one of the versions pre-warmed into this image, or the build fails."
    exit 0
fi

if [ ! -f "$POM_TEMPLATE" ]; then
    echo "ERROR: the pom.xml template '$POM_TEMPLATE' does not exist - exiting" >&2
    exit 1
fi

# The toolchain pins are baked into the image as ENV. An empty one would render a pom with an
# empty <version>, which maven only rejects much later with an opaque message - so check here.
for required_env in GRPC_JAVA_VERSION PROTOBUF_JAVA_VERSION GOOGLE_COMMON_PROTOS_VERSION \
                    MAVEN_SOURCE_PLUGIN_VERSION JAVA_RELEASE; do
    if [ -z "${!required_env}" ]; then
        echo "ERROR: the environment variable '$required_env' is empty, but the pom.xml template" >&2
        echo "       needs it. It is set by the Dockerfile ARG of the same name - exiting" >&2
        exit 1
    fi
done

echo "No pom.xml specified in source directory -> generating one from the default template"
# `|` as the s/// delimiter: maven coordinates and versions contain dots and dashes, never a
# pipe. @VERSION@ is not a substring of any other placeholder, so the order is irrelevant.
sed \
    -e "s|@GROUP_ID@|$MAVEN_GROUP_ID|g" \
    -e "s|@ARTIFACT_ID@|$MAVEN_ARTIFACT_ID|g" \
    -e "s|@VERSION@|$LIBRARY_VERSION|g" \
    -e "s|@JAVA_RELEASE@|$JAVA_RELEASE|g" \
    -e "s|@GRPC_JAVA_VERSION@|$GRPC_JAVA_VERSION|g" \
    -e "s|@PROTOBUF_JAVA_VERSION@|$PROTOBUF_JAVA_VERSION|g" \
    -e "s|@GOOGLE_COMMON_PROTOS_VERSION@|$GOOGLE_COMMON_PROTOS_VERSION|g" \
    -e "s|@MAVEN_SOURCE_PLUGIN_VERSION@|$MAVEN_SOURCE_PLUGIN_VERSION|g" \
    "$POM_TEMPLATE" > "$POM_FILE"

# A leftover placeholder means the template grew a field this script does not substitute.
# Fail here rather than ship a pom maven will choke on. BRE \{1,\} is portable (no grep -P).
if grep -q '@[A-Z_]\{1,\}@' "$POM_FILE"; then
    echo "ERROR: the generated '$POM_FILE' still contains unsubstituted placeholders:" >&2
    grep -n '@[A-Z_]\{1,\}@' "$POM_FILE" >&2
    exit 1
fi

echo "Generated $POM_FILE for $MAVEN_GROUP_ID:$MAVEN_ARTIFACT_ID:$LIBRARY_VERSION"
