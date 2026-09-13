ARG RUST_VERSION=1.98.1

FROM rust:${RUST_VERSION}-slim

# protobuf version for compiling proto files
ARG PROTOC_VERSION=32.0

# protoc plugin versions (neoeinstein/protoc-gen-prost workspace)
ARG PROTOC_GEN_PROST_VERSION=0.5.0
ARG PROTOC_GEN_TONIC_VERSION=0.5.0
ARG PROTOC_GEN_PROST_CRATE_VERSION=0.5.0

# The rust base image auto-removes wget after installing rustup but keeps gcc + libc6-dev,
# so the run-time cargo build has a working linker; wget/unzip are re-added here for protoc.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates unzip wget \
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

# --------------- Installing the prost / tonic protoc plugins
# cargo puts the binaries in $CARGO_HOME/bin (/usr/local/cargo/bin), which the base image
# already has on PATH, so protoc resolves protoc-gen-{prost,tonic,prost-crate} by name and
# no --plugin= flag is needed (protoc derives the binary name from --<name>_out).
# CARGO_TARGET_DIR is deliberately NOT set yet: cargo install must keep using its own
# throwaway target dir so these plugin builds are not baked into the shipped layer.
# Retry to ride out transient crates.io / network failures (mirrors the wget --tries above).
RUN for i in 1 2 3 4 5; do \
      cargo install --locked --version "$PROTOC_GEN_PROST_VERSION" protoc-gen-prost && \
      cargo install --locked --version "$PROTOC_GEN_TONIC_VERSION" protoc-gen-tonic && \
      cargo install --locked --version "$PROTOC_GEN_PROST_CRATE_VERSION" protoc-gen-prost-crate && \
      exit 0; \
      echo "cargo install failed (attempt $i/5); retrying in 15s ..." >&2; \
      sleep 15; \
    done; \
    echo "cargo install failed after 5 attempts" >&2; exit 1

# --------------- Fail the BUILD, not the first generation run, if a plugin is off PATH.
# All three plugins implement --version, so this costs nothing and turns protoc's generic
# "program not found or is not executable" into a build-time error.
RUN protoc --version \
 && protoc-gen-prost --version \
 && protoc-gen-tonic --version \
 && protoc-gen-prost-crate --version

# --------------- Pre-warm the cargo registry AND pre-build the dependencies, so that
# generation needs no network at all at run time. Only the pre-warm manifest is copied
# here so that editing the shell scripts below does not invalidate this (expensive) layer.
# The pre-warm manifest is a deliberate SUPERSET of the generated crate's own dependencies:
# a client that mounts its own Cargo.toml may add tokio, serde, tls features, ... and with
# CARGO_NET_OFFLINE those must already be cached. Keep the [dependencies] of
# image-data/default-lib-files/prewarm-Cargo.toml a superset of the ones in
# image-data/default-lib-files/Cargo.toml, or offline builds of client manifests break.
ENV CARGO_TARGET_DIR=/image-data/cargo-target
COPY image-data/default-lib-files/prewarm-Cargo.toml /image-data/prewarm/Cargo.toml
RUN mkdir -p /image-data/prewarm/src && \
    printf '// dependency pre-warm only - not shipped\n' > /image-data/prewarm/src/lib.rs && \
    cd /image-data/prewarm && \
    for i in 1 2 3 4 5; do \
      cargo build --release && exit 0; \
      echo "cargo build (pre-warm) failed (attempt $i/5); retrying in 15s ..." >&2; \
      sleep 15; \
    done; \
    echo "cargo build (pre-warm) failed after 5 attempts" >&2; exit 1

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
COPY image-data/ /image-data/

# --------------- Make the working dirs writable so the image also runs under
# `docker run --user $(id -u):$(id -g)` (the pattern the python target uses, and the one a
# Makefile-driven rust client copies) and so the generated crate is not root-owned.
# The base image already does `chmod -R a+w` on /usr/local/{rustup,cargo} but not /image-data.
RUN mkdir -p /image-data/cargo-target /image-data/crate /image-data/dist /image-data/src \
 && chmod -R a+w /image-data

# --------------- From here on every cargo invocation must resolve from the warmed cache;
# a stray network fetch fails fast instead of hanging in an offline runner.
ENV CARGO_NET_OFFLINE=true

# --------------- Entrypoint when the docker container is executed
ENTRYPOINT ["bash","compile-proto-2-rust.sh"]
