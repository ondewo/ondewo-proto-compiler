FROM node:14.14-buster as debugging_image

RUN apt update && apt install -y parallel unzip tree vim curl wget tree tmux

# --------------- Installing protoc (Protobuf compiler binary)
RUN wget https://github.com/protocolbuffers/protobuf/releases/download/v3.19.4/protoc-3.19.4-linux-x86_64.zip -O /tmp/protoc.zip &&\
 unzip -o /tmp/protoc.zip  -d /tmp/protoc/ &&\
 cp /tmp/protoc/bin/protoc /usr/local/bin/protoc &&\
 cp -r /tmp/protoc/include/* /usr/local/include &&\
 chmod a+x /usr/local/bin/protoc

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
ADD image-data /image-data

# --------------- Install npm modules required for compilation with angular
RUN npm run reinstall

# --------------- Entrypoint when the docker container is executed
ENTRYPOINT ["bash","compile-proto-2-angular.sh"]

# -----------------------------------------------------------------------------------------------------
