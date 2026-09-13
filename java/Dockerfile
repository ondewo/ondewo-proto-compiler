# Java toolchain versions encoded in the base image tag. Declared BEFORE `FROM`, because
# `FROM` is the only instruction that consumes them.
ARG JAVA_VERSION=21
ARG MAVEN_VERSION=3.9.16

# The `maven:` images ship a JDK and maven together - both are required, because this target
# does not only generate stubs, it also compiles and packages them into a real .jar. There is
# no `maven:*-slim` tag, so this image deliberately breaks the repo's `-slim` convention.
#
# --platform: protoc and the grpc-java plugin below are both pinned to linux-x86_64 (exactly
# like the protoc / grpc-web pins in the angular, js, nodejs and typescript images), so the
# whole image is amd64 by construction. Without this, an arm64 host would pull an arm64 base
# and then install x86_64 binaries - which builds fine and only fails at generation time with
# "exec format error".
FROM --platform=linux/amd64 maven:${MAVEN_VERSION}-eclipse-temurin-${JAVA_VERSION}

# protobuf version for compiling proto files
ARG PROTOC_VERSION=32.0

# Java toolchain pins baked into the generated library's pom.xml.
# GRPC_JAVA_VERSION pins BOTH the prebuilt protoc plugin downloaded below AND the io.grpc
# coordinates written into the pom, so the generator and the runtime can never drift apart.
ARG GRPC_JAVA_VERSION=1.84.0
# MUST stay >= 4.<PROTOC_VERSION> (the generated code is 4.32.x) and >= the protobuf-java
# version proto-google-common-protos was generated against. protobuf supports a runtime NEWER
# than the gencode, never older.
ARG PROTOBUF_JAVA_VERSION=4.33.6
# Supplies the java classes for google/api/annotations.proto, google/rpc/status.proto and
# google/type/latlng.proto, which the ondewo protos import and which are therefore NOT
# generated (that would duplicate com.google.* classes on every consumer's classpath).
ARG GOOGLE_COMMON_PROTOS_VERSION=2.76.0
# maven-source-plugin is not part of the default lifecycle, so its version has to be explicit
# or there is nothing for the offline resolution to resolve.
ARG MAVEN_SOURCE_PLUGIN_VERSION=3.4.0
# Bytecode floor of the published client SDK, independent of the JDK that builds it.
ARG JAVA_RELEASE=11
# Default <version> of the generated library when the caller passes no explicit version.
ARG ONDEWO_PROTO_COMPILER_VERSION=5.14.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates parallel unzip tree wget \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# --------------- Installing protoc (Protobuf compiler binary)
RUN wget --tries=3 --waitretry=5 --retry-connrefused \
      https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VERSION/protoc-$PROTOC_VERSION-linux-x86_64.zip \
      -O /tmp/protoc.zip && \
    unzip -o /tmp/protoc.zip -d /tmp/protoc/ && \
    cp /tmp/protoc/bin/protoc /usr/local/bin/protoc && \
    cp -r /tmp/protoc/include/* /usr/local/include && \
    chmod a+x /usr/local/bin/protoc && \
    rm -rf /tmp/protoc.zip /tmp/protoc/

# --------------- Installing the gRPC java protoc plugin (prebuilt exe from Maven Central)
# `test -s`, not `test -x`: the chmod above already made the file executable, so executability
# proves nothing about the download - only "non-empty" is still worth asserting. The plugin has
# no --version flag ("Unknown option: --version"), so the real smoke test is the seed
# generation inside warm-maven-repo.sh, which fails the docker build on a broken plugin.
RUN wget --tries=3 --waitretry=5 --retry-connrefused \
      https://repo1.maven.org/maven2/io/grpc/protoc-gen-grpc-java/$GRPC_JAVA_VERSION/protoc-gen-grpc-java-$GRPC_JAVA_VERSION-linux-x86_64.exe \
      -O /usr/local/bin/protoc-gen-grpc-java && \
    chmod a+x /usr/local/bin/protoc-gen-grpc-java && \
    test -s /usr/local/bin/protoc-gen-grpc-java

# --------------- Toolchain pins visible to the in-container scripts (pom.xml templating)
# MAVEN_REPO_LOCAL is deliberately NOT baked in here: every script derives it from
# IMAGE_DATA_DIRECTORY, so overriding that single knob moves all container paths together.
# A baked ENV literal would always win over the scripts' `${MAVEN_REPO_LOCAL:-...}` default
# and silently leave the maven repository behind when IMAGE_DATA_DIRECTORY is redirected.
ENV IMAGE_DATA_DIRECTORY=/image-data \
    GRPC_JAVA_VERSION=${GRPC_JAVA_VERSION} \
    PROTOBUF_JAVA_VERSION=${PROTOBUF_JAVA_VERSION} \
    GOOGLE_COMMON_PROTOS_VERSION=${GOOGLE_COMMON_PROTOS_VERSION} \
    MAVEN_SOURCE_PLUGIN_VERSION=${MAVEN_SOURCE_PLUGIN_VERSION} \
    JAVA_RELEASE=${JAVA_RELEASE} \
    ONDEWO_PROTO_COMPILER_VERSION=${ONDEWO_PROTO_COMPILER_VERSION}

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
COPY image-data/ /image-data/

# --------------- Pre-warm the maven local repository so generation needs NO network
# This is the ONLY networked step of the java toolchain; after it, `mvn --offline` at run time
# resolves everything from /image-data/.m2/repository. warm-maven-repo.sh proves that inside
# the build by re-running the identical build with --offline.
RUN bash /image-data/warm-maven-repo.sh && \
    chmod -R a+rX /image-data/.m2

# --------------- Entrypoint when the docker container is executed
ENTRYPOINT ["bash","compile-proto-2-java.sh"]
