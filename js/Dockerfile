ARG NODE_VERSION=22.16.0

FROM node:${NODE_VERSION}-bookworm-slim

# protobuf version for compiling proto files
ARG PROTOC_VERSION=27.3

RUN apt update && apt install -y parallel unzip tree nano wget

RUN wget https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VERSION/protoc-$PROTOC_VERSION-linux-x86_64.zip -O /tmp/protoc.zip &&\
 unzip -o /tmp/protoc.zip  -d /tmp/protoc/ &&\
 cp /tmp/protoc/bin/protoc /usr/local/bin/protoc &&\
 cp -r /tmp/protoc/include/* /usr/local/include &&\
 chmod a+x /usr/local/bin/protoc

ARG GRPC_WEB_VERSION=1.5.0
RUN wget https://github.com/grpc/grpc-web/releases/download/${GRPC_WEB_VERSION}/protoc-gen-grpc-web-${GRPC_WEB_VERSION}-linux-x86_64 -O /usr/local/bin/protoc-gen-grpc-web &&\
  chmod a+x /usr/local/bin/protoc-gen-grpc-web

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
ADD image-data/default-lib-files/package.json /image-data/default-lib-files/package.json

# --------------- Install npm modules required for compilation with webpack
RUN npm install -g protoc-gen-js
RUN npm install -g webpack
RUN npm install -g -D webpack-cli --yes

ADD image-data/default-lib-files/* /image-data/default-lib-files/

ADD image-data/* /image-data/

# --------------- Entrypoint when the docker container is executed
ENTRYPOINT ["bash","compile-proto-2-js.sh"]

# -----------------------------------------------------------------------------------------------------
