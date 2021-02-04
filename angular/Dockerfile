FROM node:14.14-buster as debugging_image

RUN apt update && apt install -y parallel unzip tree

#Installing protoc (Protobuf compiler binary)
RUN wget https://github.com/protocolbuffers/protobuf/releases/download/v3.14.0/protoc-3.14.0-linux-x86_64.zip -O /tmp/protoc.zip &&\
 unzip -o /tmp/protoc.zip  -d /tmp/protoc/ &&\
 cp /tmp/protoc/bin/protoc /usr/local/bin/protoc &&\
 cp -r /tmp/protoc/include/* /usr/local/include &&\
 chmod a+x /usr/local/bin/protoc

#Installing protoc compile web (typescript javscript) plugin
RUN wget https://github.com/grpc/grpc-web/releases/download/1.2.1/protoc-gen-grpc-web-1.2.1-linux-x86_64 -O /usr/local/bin/protoc-gen-grpc-web &&\
  chmod a+x /usr/local/bin/protoc-gen-grpc-web

#RUN npm install -g @angular/cli

WORKDIR /usr/src/app

#https://stackoverflow.com/questions/23439126/how-to-mount-a-host-directory-in-a-docker-container
#Add can be used to copy files into container at build time (-> no reference)

#Copy all files from "image-data" directory to docker container
ADD image-data /usr/src/app/
#ADD package.json /usr/src/app/package.json
#ADD package-lock.json /usr/src/app/package-lock.json
#Add angular workspace configuration to image
#ADD angular.json /usr/src/app/angular.json
#Add tsconfig that should be used if no tsconfig was specified in the input directory (mounted volume) 
#Defaults if not specified in mounted source directory volume
#ADD default-lib-files/tsconfig.json /usr/src/app/default-lib-files/tsconfig.json
#ADD default-lib-files/ng-package.json /usr/src/app/default-lib-files/ng-package.json
#Add shell script for using protbuf to compile grpc stubs from mounted volume
#ADD compile-proto-2-angular.sh /usr/src/app/compile-proto-2-angular.sh

#Install npm modules required for compilation with angular and clean cache to save space
RUN npm install
#Install angular cli globally
RUN npm install -g @angular/cli@11.0.6



#ENTRYPOINT echo 'hello world'
ENTRYPOINT bash compile-proto-2-angular.sh

# -----------------------------------------------------------------------------------------------------

#https://stackoverflow.com/questions/41935435/understanding-volume-instruction-in-dockerfile
#Defines mounted volume to which data can be transferred (find volume and add/temove data)
#Changes to the volume on host are reflected in dockerfile and vice versa
#VOLUME /usr/src/app/testprotos

#Building the image (Executed in same dir as Dockerfile)
#docker build -t mytag .

#docker run -it --entrypoint /bin/bash -v $(pwd)/protos:/usr/src/app/protos mytag
# -it --entrypoint /bin/bash mytag #--> To run an interactive bash inside the docker container: useful for debugging the image
# -v $(pwd)/testprotos:/usr/src/app/protos mytag #--> to mount host directory "./testprotos" to /usr/src/app/protos in the docker image

#docker run -it -v $(pwd)/testprotos:/src mytag

#For mounting the specified directory as input and starting in interactive mode (read/write to stdin/stdout)
#docker run -it -v $(pwd)/example:/usr/src/app/input-volume mytag


#Build to lib with just .protos should be possible (use default project files otherwise use specified values)
#Required input files for lib build:
#package.json
#ng-package.json
#public-api.ts --> ????
#proto-files