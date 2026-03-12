ARG NODE_VERSION=24.14.0

FROM node:${NODE_VERSION}-bookworm-slim

# protobuf version for compiling proto files
ARG PROTOC_VERSION=32.0

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

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
ADD image-data /image-data

# --------------- Install npm modules required for compilation with nodejs
RUN npm install
RUN npm install -g grpc-tools

# --------------- Entrypoint when the docker container is executed
ENTRYPOINT ["bash","compile-proto-2-nodejs.sh"]

# -----------------------------------------------------------------------------------------------------
