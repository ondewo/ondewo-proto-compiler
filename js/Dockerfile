FROM node:18.7.0-buster-slim as debugging_image

RUN apt update && apt install -y parallel unzip tree nano wget

RUN wget https://github.com/protocolbuffers/protobuf-javascript/archive/refs/tags/v3.21.0.zip -O /tmp/protoc.zip &&\
 unzip -o /tmp/protoc.zip  -d /tmp/protoc/ &&\
 cp /tmp/protoc/bin/protoc /usr/local/bin/protoc &&\
 cp -r /tmp/protoc/include/* /usr/local/include &&\
 chmod a+x /usr/local/bin/protoc

RUN wget https://github.com/grpc/grpc-web/releases/download/1.4.0/protoc-gen-grpc-web-1.4.0-linux-x86_64 -O /usr/local/bin/protoc-gen-grpc-web &&\
  chmod a+x /usr/local/bin/protoc-gen-grpc-web

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
ADD image-data/default-lib-files/package.json /image-data/default-lib-files/package.json

# --------------- Install npm modules required for compilation with webpack
#RUN npm install
RUN npm install -g webpack@5.74.0
RUN npm install -g webpack-cli

ADD image-data/default-lib-files/* /image-data/default-lib-files/

ADD image-data/* /image-data/

# --------------- Entrypoint when the docker container is executed
ENTRYPOINT ["bash","compile-proto-2-js.sh"]

# -----------------------------------------------------------------------------------------------------