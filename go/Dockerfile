ARG GO_VERSION=1.27

FROM golang:${GO_VERSION}

# ARGs declared before FROM are only in scope for the FROM itself -> re-declare
ARG GO_VERSION=1.27

# protobuf version for compiling proto files
ARG PROTOC_VERSION=32.0

# protoc-gen-go doubles as the pin of the google.golang.org/protobuf runtime (same module)
ARG PROTOC_GEN_GO_VERSION=1.36.12
# protoc-gen-go-grpc is its own module, versioned independently of google.golang.org/grpc
ARG PROTOC_GEN_GO_GRPC_VERSION=1.6.2
ARG GRPC_GO_VERSION=1.83.2
# go-genproto publishes no semver tags - this is a pseudo-version and carries its own "v"
ARG GENPROTO_VERSION=v0.0.0-20260911204522-f61a6ca850bd
# `go` directive of the generated go.mod; must be >= grpc's own (`go 1.25.0`)
ARG GO_MOD_DIRECTIVE=1.25.0

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

# --------------- Install the go protoc plugins (they land in $GOPATH/bin, already on PATH)
# GOCACHE is pointed at its final location BEFORE the plugins are built, so the hundreds of MB
# of build cache `go install` produces are the same cache the warm-up below reuses instead of a
# second, never-read copy under /root/.cache/go-build being baked into the image.
ENV GOCACHE=/go/build-cache
# Retry to ride out transient proxy.golang.org failures (mirrors the wget --tries above).
RUN for i in 1 2 3 4 5; do \
      go install google.golang.org/protobuf/cmd/protoc-gen-go@v${PROTOC_GEN_GO_VERSION} && \
      go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v${PROTOC_GEN_GO_GRPC_VERSION} && exit 0; \
      echo "go install failed (attempt $i/5); retrying in 15s ..." >&2; \
      sleep 15; \
    done; \
    echo "go install failed after 5 attempts" >&2; exit 1

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
COPY image-data/ /image-data/

# --------------- Resolve + pre-download everything the generated stubs are built against
# Generation itself must not touch the network, so the module graph is resolved exactly once,
# here, and frozen into default-lib-files/go.mod.template + go.sum. default-lib-files/warmup.go
# imports precisely the packages protoc-gen-go / protoc-gen-go-grpc emit imports for, so
# `go mod tidy` cannot prune a module the generated stubs will need.
RUN set -e; \
    mkdir -p /tmp/warmup; \
    cp /image-data/default-lib-files/warmup.go /tmp/warmup/warmup.go; \
    cd /tmp/warmup; \
    go mod init ondewo.local/warmup; \
    go mod edit -go=${GO_MOD_DIRECTIVE} \
      -require=google.golang.org/protobuf@v${PROTOC_GEN_GO_VERSION} \
      -require=google.golang.org/grpc@v${GRPC_GO_VERSION} \
      -require=google.golang.org/genproto@${GENPROTO_VERSION} \
      -require=google.golang.org/genproto/googleapis/api@${GENPROTO_VERSION} \
      -require=google.golang.org/genproto/googleapis/rpc@${GENPROTO_VERSION}; \
    go mod tidy; \
    go mod edit -toolchain=none; \
    go mod download; \
    go build ./...; \
    sed -e "s|^module .*|module @GO_MODULE_PATH@|" go.mod \
      > /image-data/default-lib-files/go.mod.template; \
    cp go.sum /image-data/default-lib-files/go.sum; \
    cd /; \
    rm -rf /tmp/warmup

# --------------- Generation runs offline: every module it needs is in the caches warmed above.
# GOPROXY=off turns a missing module into a loud "module lookup disabled by GOPROXY=off"
# instead of a silent network fetch; GOTOOLCHAIN=local forbids a toolchain download.
ENV GOPROXY=off \
    GOFLAGS=-mod=readonly \
    GOTOOLCHAIN=local

# --------------- Entrypoint when the docker container is executed
ENTRYPOINT ["bash","compile-proto-2-go.sh"]
