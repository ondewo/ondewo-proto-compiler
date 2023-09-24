FROM node:18.18-buster-slim as debugging_image

RUN apt update && apt install -y parallel unzip tree wget

# --------------- Installing protoc (Protobuf compiler binary)
RUN wget https://github.com/protocolbuffers/protobuf/releases/download/v3.20.1/protoc-3.20.1-linux-x86_64.zip -O /tmp/protoc.zip &&\
 unzip -o /tmp/protoc.zip  -d /tmp/protoc/ &&\
 cp /tmp/protoc/bin/protoc /usr/local/bin/protoc &&\
 cp -r /tmp/protoc/include/* /usr/local/include &&\
 chmod a+x /usr/local/bin/protoc

# --------------- Installing protoc compile web (typescript javscript) plugin
RUN wget https://github.com/grpc/grpc-web/releases/download/1.3.1/protoc-gen-grpc-web-1.3.1-linux-x86_64 -O /usr/local/bin/protoc-gen-grpc-web &&\
  chmod a+x /usr/local/bin/protoc-gen-grpc-web

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
ADD image-data /image-data

# --------------- Install npm modules required for compilation with angular
#RUN npm install
#RUN npm install -g typescript

# --------------- Entrypoint when the docker container is executed
ENTRYPOINT ["bash","compile-proto-2-typescript.sh"]

# -----------------------------------------------------------------------------------------------------
