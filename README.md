<p align="center">
    <a href="https://www.ondewo.com">
      <img alt="ONDEWO Logo" src="https://raw.githubusercontent.com/ondewo/ondewo-logos/master/github/ondewo_logo_github_2.png"/>
    </a>
  <h1 align="center">
    Ondewo Proto Compiler
  </h1>
</p>

A collection of docker images for the purpose of creating installable client packages from the protcol buffer definition (.proto) files.

## Platforms ##

The ondewo proto compiler docker images are available for following target platforms:

### Angular ###

Uses **ngx-grpc**'s **protoc-gen-ng** to compile the .proto files of the source directory to injectable typescript services and classes for to use as a client.  
Then proceeds to package these classes to a npm installable grpc client library using **ng-packagr** and the angular compiler. 

Also creates a `npm`-folder which can be published to NPM by running `npm run publish-npm` in the `src` folder of the corresponding project.
(**IMPORTANT**: Check the versions in the package.json and RELEASE.md files. These versions should match the GitHub release.)

### (Vanilla) - Javascript ###

Also uses **grpc-web** to compile the protobuf defs to commonjs.  
Then uses webpack to transpile the commonjs classes to a single vanilla javascript that can be included from a <\script>-tag of a webpage.

### Node.js ###

Uses the npm **grpc-tools** and **grpc_tools_node_protoc_ts** to compile the .proto files of the source directory to commonjs service/classes and type definitions to consume those classes in a node client. (uses commonjs,binary options for performant communication)  
Then proceeds to create an entry point file for all resulting classes and creates an npm installable typescript package.

### Typescript ###

Uses the **grpc-web** protobuf compiler plugin to compile the .proto files of the source directory to commonjs service/classes and type definitions to consume those classes in typescript. (uses commonjs,binary options for performant communication)  
Then proceeds to create an entry point file for all resulting classes and creates an npm installable typescript package.

## How to use? ##

### Requirements ###

- Docker:  
   
    ```bash
    #Removing old versions
    sudo apt-get remove docker docker-engine docker.io
    #Ubuntu
    sudo apt install containerd docker.io
    sudo systemctl start docker
    sudo systemctl enable docker
    ```
On Windows using **Windows Subsystem for Linux (WSL)** is recommended, to prevent any compability issues.

### Building the docker images ###

```bash
bash angular/build.sh
bash js/build.sh
bash nodejs/build.sh
bash typescript/build.sh
```
Creates the following image tags:
- Angular:
ondewo-angular-proto-compiler
- Javascript:
ondewo-js-proto-compiler
- Node.js:
ondewo-nodejs-proto-compiler
- Typescript:
ondewo-typescript-proto-compiler

### Using the docker images to consume .proto directories and create platform specific client packages ###

Examples of usage can be found in:  
- angular/example
- js/example
- nodejs/example

Where the script **run-compile.sh** performs the .proto to package compilation.  

To compile a package following format should be followed:

```bash
docker run -it -v $FILEDIRECTORY:/input-volume -v $FILEDIRECTORY/lib:/output-volume ondewo-angular-proto-compiler protos
```
- **-it** Interactive terminal to show the output of the compilation process in the active terminal
- **-v** specifies the input directory to mount and consume for the compilation (path after the **:**)
- **-v** specifies the output directory where the resulting package files are copied to
- **Tag** of the docker image to be used (options according to the corresponding image tags as specified above)
- Relative path to the input volume where the **.proto files** are located
