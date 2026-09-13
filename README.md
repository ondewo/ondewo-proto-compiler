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

### PHP ###

Uses protoc's built-in **--php_out** for the messages and enums and **grpc_php_plugin** for the service stubs.
Then proceeds to package the generated classes as a **composer** installable library, with the autoloader generated
by `composer dump-autoload`.

### Go ###

Uses **protoc-gen-go** and **protoc-gen-go-grpc** to compile the .proto files of the source directory to Go structs
and gRPC client/server interfaces.
Then proceeds to package the result as a Go module and verifies it with `go build`.

### Rust ###

Uses **protoc-gen-prost**, **protoc-gen-tonic** and **protoc-gen-prost-crate** to compile the .proto files of the
source directory to `prost` message types and `tonic` gRPC clients.
Then proceeds to package the result as a cargo crate and verifies it with `cargo build`.

### C++ ###

Uses protoc's built-in **--cpp_out** for the messages and **grpc_cpp_plugin** for the service stubs.
Then proceeds to package the result as a CMake library target and builds it with `cmake --build`.

### Java ###

Uses protoc's built-in **--java_out** for the messages and **protoc-gen-grpc-java** for the service stubs.
Then proceeds to package the result as a Maven artifact and builds it with `mvn package`, resolving every
dependency from the local repository pre-warmed into the image.

### C# ###

Uses protoc's built-in **--csharp_out** for the messages and **grpc_csharp_plugin** (shipped by the **Grpc.Tools**
NuGet package) for the service stubs.
Then proceeds to package the result as a NuGet package and builds it with `dotnet build`, restoring every
dependency from the offline feed pre-warmed into the image.

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

### Building the docker images ###

```bash
bash angular/build.sh
bash js/build.sh
bash nodejs/build.sh
bash typescript/build.sh
bash python/build.sh
bash php/build.sh
bash go/build.sh
bash rust/build.sh
bash cpp/build.sh
bash java/build.sh
bash csharp/build.sh

```

On Windows, every target ships the equivalent `build.bat` next to its `build.sh`
(`angular\build.bat`, `go\build.bat`, …), and `build-all.bat` builds them all.
`bash build-all.sh` / `make build` does the same on Linux and macOS, and
`make build_<lang>` builds a single image.

Creates the following image tags:

- Angular:
ondewo-angular-proto-compiler
- Javascript:
ondewo-js-proto-compiler
- Node.js:
ondewo-nodejs-proto-compiler
- Typescript:
ondewo-typescript-proto-compiler
- Python:
ondewo-python-proto-compiler
- PHP:
ondewo-php-proto-compiler
- Go:
ondewo-go-proto-compiler
- Rust:
ondewo-rust-proto-compiler
- C++:
ondewo-cpp-proto-compiler
- Java:
ondewo-java-proto-compiler
- C#:
ondewo-csharp-proto-compiler

### Using the docker images to consume .proto directories and create platform specific client packages ###

- angular/example
- js/example
- nodejs/example

Where the script **run-compile.sh** performs the .proto to package compilation.

To compile a package following format should be followed:

```bash
docker run -v $FILEDIRECTORY:/input-volume -v $FILEDIRECTORY/lib:/output-volume ondewo-angular-proto-compiler protos
```

- **-it** Interactive terminal to show the output of the compilation process in the active terminal
- **-v** specifies the input directory to mount and consume for the compilation (path after the **:**)
- **-v** specifies the output directory where the resulting package files are copied to
- **Tag** of the docker image to be used (options according to the corresponding image tags as specified above)
- Relative path to the input volume where the **.proto files** are located
