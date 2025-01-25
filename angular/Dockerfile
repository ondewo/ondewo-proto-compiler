FROM node:22.13-bullseye-slim

# protobuf version for compiling proto files
# ARG PROTOC_VERSION=28.3

RUN apt update && apt install -y parallel gnupg gnupg2 wget sed vim tmux curl unzip tree ranger make gcc g++

# --------------- Installing protoc (Protobuf compiler binary)
#RUN wget https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VERSION/protoc-$PROTOC_VERSION-linux-x86_64.zip -O /tmp/protoc.zip &&\
# unzip -o /tmp/protoc.zip  -d /tmp/protoc/ &&\
# cp /tmp/protoc/bin/protoc /usr/local/bin/protoc &&\
# cp -r /tmp/protoc/include/* /usr/local/include &&\
# chmod a+x /usr/local/bin/protoc

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
ADD image-data /image-data

# --------------- Install npm modules required for compilation with angular
RUN npm install

# --------------- Entrypoint when the docker container is executed
# CMD ["bash","compile-proto-2-angular.sh"]
ENTRYPOINT ["bash","compile-proto-2-angular.sh"]

# -----------------------------------------------------------------------------------------------------
