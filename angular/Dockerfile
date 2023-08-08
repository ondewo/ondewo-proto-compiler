FROM node:18.12-buster-slim

RUN apt update && apt install -y parallel gnupg gnupg2 wget sed vim tmux curl unzip tree

# --------------- Installing protoc (Protobuf compiler binary)
RUN wget https://github.com/protocolbuffers/protobuf/releases/download/v23.4/protoc-23.4-linux-x86_64.zip -O /tmp/protoc.zip &&\
 unzip -o /tmp/protoc.zip  -d /tmp/protoc/ &&\
 cp /tmp/protoc/bin/protoc /usr/local/bin/protoc &&\
 cp -r /tmp/protoc/include/* /usr/local/include &&\
 chmod a+x /usr/local/bin/protoc

RUN echo "hl"
# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
ADD image-data /image-data

RUN npm install -g npm@9.8.1

# --------------- Install npm modules required for compilation with angular
RUN npm run reinstall

# --------------- Entrypoint when the docker container is executed
# CMD ["bash","compile-proto-2-angular.sh"]
ENTRYPOINT ["bash","compile-proto-2-angular.sh"]

# -----------------------------------------------------------------------------------------------------
