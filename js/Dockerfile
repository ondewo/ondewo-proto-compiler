FROM node:20.12-buster-slim as debugging_image

# protobuf version for compiling proto files
ARG PROTOC_VERSION=27.3

RUN apt update && apt install -y parallel unzip tree nano wget

RUN wget https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VERSION/protoc-$PROTOC_VERSION-linux-x86_64.zip -O /tmp/protoc.zip &&\
 unzip -o /tmp/protoc.zip  -d /tmp/protoc/ &&\
 cp /tmp/protoc/bin/protoc /usr/local/bin/protoc &&\
 cp -r /tmp/protoc/include/* /usr/local/include &&\
 chmod a+x /usr/local/bin/protoc

RUN wget https://github.com/grpc/grpc-web/releases/download/1.5.0/protoc-gen-grpc-web-1.5.0-linux-x86_64 -O /usr/local/bin/protoc-gen-grpc-web &&\
  chmod a+x /usr/local/bin/protoc-gen-grpc-web

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
ADD image-data/default-lib-files/package.json /image-data/default-lib-files/package.json

# --------------- Install npm modules required for compilation with webpack
#RUN npm install
RUN npm install -g webpack@5.91.0
RUN npm install -g webpack-cli

ADD image-data/default-lib-files/* /image-data/default-lib-files/

ADD image-data/* /image-data/

# --------------- Entrypoint when the docker container is executed
ENTRYPOINT ["bash","compile-proto-2-js.sh"]

# -----------------------------------------------------------------------------------------------------
