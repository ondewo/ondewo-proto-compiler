# Release History

*****************

## Release ONDEWO Proto Compiler 5.5.2

### Bug Fixes

* Fix version in angular.json

*****************

## Release ONDEWO Proto Compiler 5.5.1

### Bug Fixes

* Fixed for automated update of Dockerfile.utils versions algorithm
  in [update_proto_compiler_dependency.sh](update_proto_compiler_dependency.sh)

*****************

## Release ONDEWO Proto Compiler 5.5.0

### Improvements

* Improved automated update of library versions script to also update NODE_VERSION in
  `Dockerfile.utils` in [update_proto_compiler_dependency.sh](update_proto_compiler_dependency.sh)
* Improved `Makefile` to also update all `Dockerfile` files to the version set for `PYTHON_VERSION`, `NODE_VERSION`,
  `PROTOC_VERSION`, and `GRPC_WEB_VERSION`

*****************

## Release ONDEWO Proto Compiler 5.4.1

### Bug Fixes

* Fixed for automated update of library versions script for python since there is no `package.json` to
  `git add` [update_proto_compiler_dependency.sh](update_proto_compiler_dependency.sh)

*****************

## Release ONDEWO Proto Compiler 5.4.0

### New Features

* Automated update of library versions for Angular, Javascript, Nodejs, and Typescript with
  script [update_proto_compiler_dependency.sh](update_proto_compiler_dependency.sh)

### Improvements

* Updated to node:22.16.0-bookworm-slim for Angular, Javascript, Nodejs, and Typescript
* Angular:
    * Updated to Angular 19 libraries
    * Upgraded to node:22.16.0-bookworm-slim
* Javascript:
    * Upgraded to node:22.16.0-bookworm-slim
* Nodejs:
    * Upgraded to node:22.16.0-bookworm-slim
* Typescript:
    * Upgraded to node:22.16.0-bookworm-slim

*****************

## Release ONDEWO Proto Compiler 5.3.0

### Improvements

* Angular:
    * Updated to Angular 19 libraries

*****************

## Release ONDEWO Proto Compiler 5.2.0

### Bug Fixes

* Python:
    * Added condition for <1.68.0 for grpcio libraries

*****************

## Release ONDEWO Proto Compiler 5.1.0

### Improvements

* Typescript:
    * Upgraded to protoc v27.3

### Bug Fixes

* Typescript:
    * Added installation of protoc-gen-js to fix error "protoc-gen-js: program not found or is not executable"

*****************

## Release ONDEWO Proto Compiler 5.0.0

### Improvements

* Angular:
    * Upgraded to protoc v27.3
    * Upgraded to Angular >=18.2.8
* Javascript:
    * Upgraded to protoc v27.3
* Node.js:
    * Upgraded to protoc v27.3
* Python:
    * Upgraded to grpc 1.67.1
    * Upgraded to protobuf==5.27.5

*****************

## Release ONDEWO Proto Compiler 4.8.0

### Improvements

* Python:
    * Upgraded to grpc 1.59.2
    * Upgraded python 3.9.18

*****************

## Release ONDEWO Proto Compiler 4.7.0

### Bug fixes

* Angular 16 upgrade of angular libraries

*****************

## Release ONDEWO Proto Compiler 4.6.0

### Bug fixes

* Angular generation without proto label "optional"

*****************

## Release ONDEWO Proto Compiler 4.5.0

### Improvements

* Angular generation updated with new grpc libraries

*****************

## Release ONDEWO Proto Compiler 4.4.0

### Improvements

Angular generation updated with new grpc library and es2022 generation

*****************

## Release ONDEWO Proto Compiler 4.3.0

### Improvements

* Angular optimization flag added in ng build

*****************

## Release ONDEWO Proto Compiler 4.2.0

### Improvements

* Upgraded to newest nodejs, python and compiler versions

*****************

## Release ONDEWO Proto Compiler 4.1.2

### Improvements

* Commented out creations of .github-folder for Angular Compiler

*****************

## Release ONDEWO Proto Compiler 4.1.1

### Bug fixes

* Removed end-limit on cut commands in google-proto-dependency-automation for nodejs and typescript

*****************

## Release ONDEWO Proto Compiler 4.1.0

### Bug fixes

* Fixed bug where multiple occurences of same google proto dependency werent removed

*****************

## Release ONDEWO Proto Compiler 4.0.0

### Improvements

* Automated google-proto dependencies-reading for typescript
* Automated google-proto dependencies-reading for nodejs
* Updated Dockerfile image to node:18.7.0-buster-slim for JS, NodeJs and Typescript Compiler
* Updated protoc-gen-grpc-web (Dockerfile) to 1.3.1 for JS, NodeJs and Typescript Compiler

*****************

## Release ONDEWO Proto Compiler 3.0.0

### Improvements

* Upgraded libraries for Compilers

*****************

## Release ONDEWO Proto Compiler 2.1.0

### Improvements

* Upgraded libraries for Angular Proto-Compiler
* Turned off command line prompt for google analytics

*****************

## Release ONDEWO Proto Compiler 2.0.0

### New Features

* Upgraded all libraries to newest version

### Bug fixes

* Makefile. Added checks if directory exists

*****************

## Release ONDEWO Proto Compiler 1.1.1

### New Features

* Proto compiler for Python is now easier to use and more general

*****************

## Release ONDEWO Proto Compiler 1.1.0

### New Features

* Proto compiler for Angular now uses `ngx-grpc` 2.1.0 instead of 0.x.x
* Proto compiler for Angular creates `npm`-folder which can then be published to NPM

*****************

## Release ONDEWO Proto Compiler 1.0.0

### New Features

* Proto compiler for angular
* Proto compiler for javascript
* Proto compiler for nodejs (generates js and ts)
* Proto compiler for python
* Proto compiler for typescript
