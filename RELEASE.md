# Release History

*****************

## Release ONDEWO Proto Compiler 5.15.7

### Bug Fixes

* Angular: client-streaming and bidirectional-streaming RPCs are no longer generated as service-client methods. gRPC-web cannot send a request stream from a browser, so such a method - e.g. `streamCallAudio(requestData: Observable<StreamCallAudioRequest>)` in `@ondewo/vtsi-client-angular` 9.0.0, `sipStreamCallAudio`, `streamingDetectIntent`, `transcribeStream`, `streamingSynthesize`, `ragUploadDocument`, `s2sStream` - type-checked and could never work. protoc-gen-grpc-web, which the js and typescript targets use, never generates them; the angular target now matches it. `@ngx-grpc/protoc-gen-ng` has no option for this, so the new protoc plugin wrapper `angular/image-data/omit-client-streaming-methods.js` drops every method with `client_streaming = true` from the `CodeGeneratorRequest` before protoc-gen-ng reads it, names each omitted method on stderr, and fails the run on a malformed request. Every message type, including the request and response messages of an omitted RPC, is still generated; unary and server-streaming methods are unchanged. A client that needs a request stream (live call audio, streaming recognition or synthesis) uses a native SDK (python, nodejs, go, ...). New bats cases in `tests/angular_client_streams.bats` run the wrapper over a real `CodeGeneratorRequest` fixture.

*****************

## Release ONDEWO Proto Compiler 5.15.6

### Bug Fixes

* Typescript: the google dependency list is closed over its own imports, as the nodejs target's has been since 5.15.5. The typescript target collected only the google/ protos the selected protos import directly, so `google/api/annotations.proto` was compiled without its own import `google/api/http.proto`: `annotations_pb.js` requires `../../google/api/http_pb.js`, which was never generated, and loading any client module that reaches `annotations_pb` failed with `Cannot find module` (`@ondewo/nlu-client-typescript` 7.3.1, `@ondewo/survey-client-typescript` 2.0.2). Every listed proto is now re-read until no new import appears. A client's `src/proto-deps.txt` that pre-seeds `google/api/http.proto` as a workaround is redundant from this release on, but harmless. The other targets were checked and need no change: js, rust, cpp and php resolve imports recursively, nodejs has the closure since 5.15.5, angular's `ng build` fails on an unresolved import, and python, go, java and csharp take the google protos from their runtime libraries instead of generating them.

*****************

## Release ONDEWO Proto Compiler 5.15.5

### Bug Fixes

* Nodejs: `require('<package>')` works. The generated `public-api.js` - the package's `main` - was a list of `export * from` lines in a commonjs package whose stubs are all commonjs, so Node 20.19+, 22 and 24 loaded it as an ES module and failed with `ERR_MODULE_NOT_FOUND` on the first extensionless path (older Node threw a `SyntaxError`). It is now a commonjs barrel: one `reexport(require('./api/...'));` per stub in sorted order, where the first stub that exports a name keeps it, the same binding the `.d.ts` barrel's explicit re-exports make. `append-auth-exports.sh` appends the hand-written `auth/` modules as `reexport(require('./auth/<module>'));` to such a barrel; the `.d.ts` barrel and the typescript target's `.js` barrel keep their `export *` lines.
* Nodejs: the google dependency list is closed over its own imports. The scan of the `google/` tree skips its excluded paths, but `google/api/service.proto` put `google/api/experimental/experimental.proto` on the list, whose own import `authorization_config.proto` was never compiled - `experimental_pb.js` required a stub that did not exist, so loading the barrel failed even after the first fix. Every listed proto is now re-read until no new import appears.

*****************

## Release ONDEWO Proto Compiler 5.15.4

### Bug Fixes

* Rust: the image pre-warms tonic's `tls-native-roots` feature (with `rustls-native-certs`) and `tracing`. The rust clients' hand-written `src/channel.rs` trusts the platform certificate store when no custom CA is configured and logs its insecure-channel warning through `tracing`; generation runs fully offline, so with 5.15.3 `make generate_ondewo_protos` of every rust client failed in `cargo build --offline` because `rustls-native-certs` was not in the image's cargo cache. No other target changed.

*****************

## Release ONDEWO Proto Compiler 5.15.3

### Bug Fixes

* Python: a `.proto` file or directory with a hyphen in its name compiles again. `grpc_tools.protoc` names the python module after the proto path with every `-` turned into `_` and every `.` into `/`, directories included, so `ondewo/s2t/speech-to-text.proto` yields `ondewo/s2t/speech_to_text_pb2.py`. The post-protoc check added in 5.15.2 looked for `speech-to-text_pb2.py` instead and aborted with `grpc_tools.protoc reported success ... but produced no ...`, which broke the s2t, csi and vtsi python client builds on 5.15.2. The check now applies protoc's naming rule; the bats `python` mock writes its stubs under the same rule, and two cases pin it.

*****************

## Release ONDEWO Proto Compiler 5.15.2

### Bug Fixes

* PHP: a client that mounts one directory as both the input and the output volume - as ondewo-nlu-client-php does - can generate a second time. When the output volume holds a hand-written `auth/`, a run adds `"auth/"` to the shipped `autoload.classmap`; the next run merged that same manifest into a package staged with `src/` and `composer.json` only, and `composer update` aborted with `Could not scan for classes inside "auth/"`. The manifest merge in `make-lib-entry-point.sh` now drops `"auth/"` before the package is staged, and the existing step after the copy-back adds it back whenever the output volume has `auth/`, so the shipped `composer.json` is unchanged and repeated runs are byte-identical. A client that removes the entry itself after every run can drop that workaround once it pins this release. The bats `composer` mock now fails on a classmap entry that does not exist, like the real tool; the old mock never read the classmap, which is how the existing idempotency case passed.
* Rust: a crate manifest that names a `readme` or a `license-file` no longer fails every run. The image assembled its crate from `src/` and `Cargo.toml` only, so `cargo package` refused a manifest carrying `readme = "README.md"` with ``readme `README.md` does not appear to exist``. The files the `[package]` table names are now taken over from the input volume - a basic or literal string, and `readme = true`, cargo's alias for `README.md` - and nothing else: a manifest without the keys gets the same crate as before, a named file the input volume lacks is reported and left to `cargo package`'s own error, and an absolute path or one containing `..` is not copied. The client still stages the named file into the input volume beside its `Cargo.toml`. The packaged `.crate` now carries the README.
* Javascript: the default library `package.json` depends on `google-protobuf` `^4.0.2` instead of `^3.21.4`. The generated stubs read strings with `readStringRequireUtf8()`, which google-protobuf 3.x does not have, and a js bundle embeds its runtime - so a bundle built against `^3.21.4` cannot decode a single string field. `release_update_proto_compiler_dependency` copies the image's dependency versions into every js client's `src/package.json`, so a compiler release put clients that had moved to 4.x back on `^3.21.4` - ondewo-nlu-client-js had to restore `^4.0.2` after the 5.15.0 bump. A js client without a `package.json` of its own now also gets `^4.0.2`.
* Pre-commit: commits on ticket branches are accepted again. `giticket` was declared before `conventional-pre-commit`; both run at the commit-msg stage in declaration order, so the validator, which anchors its pattern at the start of the subject, rejected the `[OND211-2418] feat: ...` subject giticket had just written - every commit on a ticket branch failed. The validator now runs first. A new local `strip-ticket-prefix` hook runs before both and removes a ticket prefix an earlier run added, so `git commit --amend`, a rebase reword or `-C HEAD` validate the plain subject and end with exactly one prefix instead of being rejected or doubled.
* Release automation: the GitHub release body is the whole section again. `CURRENT_RELEASE_NOTES` ended its slice of `RELEASE.md` at the first bold span inside the notes instead of at the `*****` separator, which is how the 5.15.0 release was published with 3 of its 8 lines. The slice now ends on `^\*{5}`, and its opening heading is anchored and matched literally, so a version that is a prefix of a newer one (`1.1.1` vs `1.1.10`) cannot select the newer section.

### Improvements

* Release automation: `make release` runs `check_release_credentials`, the new `check_release_notes` and `spc` before it pushes anything. The GitHub token used to be checked only inside the utils image, after the version commits, the release branch and the tag were already on origin, and a direct `make release` found an already-used version only at `git checkout -b`. `check_release_notes` fails when `RELEASE.md` has no notes for the version, instead of letting `gh release create` publish an empty body. The `Makefile`'s "BEFORE RELEASE" header now lists the steps that actually exist.

*****************

## Release ONDEWO Proto Compiler 5.15.1

### Bug Fixes

* Nodejs: the shipped example compiled again - and with it every client whose protos import another proto. The proto-dependency list was parsed by column position (`cut -c 8-`), so `dependency/myimport.proto` reached protoc as `ncy/myimport.proto` and the run died with "Could not make proto path relative". The same positional parsing mangled an indented import, a legal `import public` / `import weak`, and any path a client had pre-seeded into its own `proto-deps.txt`. Imports are now matched as statements with a single anchored expression, so only the quoted path is ever extracted. Two further defects in the same block went with it: the de-duplication built an unanchored `grep` pattern out of each chopped token, so a commented-out `// import "google/...";` yielded the token `ort`, matched every other line and deleted the rest of the dependency list; and the final collapse used `sort | uniq -u`, which prints only lines occurring exactly once and therefore *dropped* a dependency instead of de-duplicating it. Typescript carried the identical block and is fixed the same way.
* Angular: a failed run no longer destroys the client's existing library. The output volume was wiped - `package.json`, `public-api.ts`, `public-api.d.ts`, `npm/`, `api/` and nine more entries - *before* any input requirement was checked, so a missing `package.json`, a protos directory that does not exist or a typo'd target sub-directory deleted the previous output and left nothing to restore from. All seven angular clients mount their own repository root as the output volume. Validation now runs first and the wipe only once the run is committed to producing output; every `rm -rf` in the target also gained the `${VAR:?}` guard the other targets already used.
* Javascript: a proto whose filename contains a newline is rejected instead of silently dropped. `while IFS= read -r` split such a name into two fragments, neither a file; the root-prefix fixup then built a nonsense path and both `relativeToRoot` and `sed` failed on stderr while the function still returned 0. Measured against the real image: the run exited 0, webpack reported "compiled successfully", and the shipped bundle contained no trace of the dropped proto's messages. The resolver now asserts the path is a readable file and exits non-zero, as the cpp and rust copies already did.
* All eleven targets: a directory whose name ends in `.proto` is no longer mistaken for an input file, and a *symlinked* proto is compiled again. Adding `-type f` to the discovery `find` in 5.15.0 fixed the first and quietly introduced the second, because `-type f` tests the link rather than its target. Discovery is now spelled the same way everywhere - match by name, then keep what `test -f` accepts - and a `.proto` symlink that resolves to nothing is a named error rather than a silent omission. Symlink loops terminate with the same error instead of hanging.
* All eleven targets: a generator that exits 0 having written nothing is now a failure everywhere. Angular, js, nodejs, typescript and go computed a generated-stub count, printed it and ignored it, so "protoc reported success but produced no output" passed silently in exactly the targets that have shipped longest. One of them counted the whole staged input volume rather than the generated tree, which made the number meaningless.
* Python: the entry-proto list is no longer word-split or glob-expanded. `for f in $files` broke a path containing a space into two bogus arguments, dropped a proto named e.g. `[a].proto` through pathname expansion, and split a newline-bearing name in two. The `run` target additionally mounted the caller's whole working directory when `PROTO_DIR`, `OUTPUT_DIR` or `EXTRA_PROTO_DIR` was empty, and never checked that its mount sources exist.
* Release automation: a `jq` failure can no longer commit an empty `package.json` to a client repository. `jq … > "$TMP" && mv "$TMP" "$TARGET"` is an AND-OR list, which `set -e` is specified not to act on, so a failing `jq` left the already-truncated temp file to be installed over the client's manifest - and the script then committed and pushed it.
* Release automation: `update_proto_compiler_dependency.sh` also rewrites the client's own `ONDEWO_PROTO_COMPILER_GIT_BRANCH`. It previously moved only the submodule gitlink, so the client's `update_submodules` target checked the *previous* compiler back out and silently undid the bump.
* Tests: the suite passes on the `macos-latest` CI leg again. `mktemp -d` returns a symlinked path there (`/var/folders` → `/private/var/folders`) while a Makefile's `$(shell pwd)` reports the resolved form, so assertions comparing a docker mount against the sandbox path failed on macOS while passing on Linux.

### Improvements

* The portability gate scans the bats suite itself, not just the production scripts, and gained rules for `wc -l` used as a counter, template-less `mktemp`, and GNU-only basic-regex escapes (`\|`, `\+`, `\?`) - one of which was already being used in an existing assertion, where BSD grep would have interpreted it as a literal.
* `tests/consistency.bats` pins the three cross-cutting properties above across **all eleven** targets from one table, and fails if that table ever stops matching the target directories on disk - so a twelfth target cannot be added without satisfying them.

*****************

## Release ONDEWO Proto Compiler 5.15.0

### New Features

* Six new language targets - **php**, **go**, **rust**, **cpp**, **java** and **csharp** - each built to the same shape as the existing five: a `Dockerfile` pinning its toolchain through `ARG` lines, a `build.sh`, a `<lang>/Makefile` with `build` / `run`, an `example/` tree with a service-bearing `test.proto` and an imported `dependency/myimport.proto`, and an `image-data/` pipeline of `compile-proto-2-<lang>.sh` → `compile-proto-2-stubs.sh` → `compile-stubs-2-lib.sh`. Every target copies `/input-volume` into an internal temp directory and compiles there, so the mounted input is never mutated, writes only to `/output-volume`, wipes its own generated output there before copying so a renamed or deleted proto leaves no orphan behind, and honours the `IMAGE_DATA_DIRECTORY` / `INPUT_VOLUME_FS` / `OUTPUT_VOLUME_FS` / `TEMP_SRC_DIRECTORY` overrides that let the bats suite drive the whole pipeline on the host without Docker. php generates with protoc's built-in `--php_out` plus `grpc_php_plugin` and packages with composer; go with `protoc-gen-go` + `protoc-gen-go-grpc` and `go build`; rust with `protoc-gen-prost` + `protoc-gen-tonic` + `protoc-gen-prost-crate` and `cargo build`; cpp with `--cpp_out` plus `grpc_cpp_plugin` and a CMake library target; java with `--java_out` plus `protoc-gen-grpc-java` and `mvn package`; csharp with `--csharp_out` plus `grpc_csharp_plugin` and `dotnet build`. Each image pre-warms its dependency cache at build time and runs its package build in the toolchain's offline mode (`GOPROXY=off`, `COMPOSER_DISABLE_NETWORK`, `mvn -o`, `--no-restore`, a vendored cargo registry), so generation needs no network once the image exists and a cache miss fails loudly instead of silently reaching out.
* Windows batch wrappers for **every** target. `build.bat` sits beside each `build.sh` and `example/run-compile.bat` beside each `example/run-compile.sh`, with `build-all.bat` alongside `build-all.sh`. Each resolves its own directory from `%~dp0` rather than the caller's working directory and checks `errorlevel` after the docker invocation, so a failed build propagates instead of being masked by a trailing success message - the same silent-failure class that was fixed on the `sh` side.

### Improvements

* The release automation now propagates versions for all eleven targets. `release_version_update_in_dockerfiles` is driven by two Makefile lists - `DOCKERFILES` and `DOCKERFILE_ARGS` - instead of a hand-maintained `perl` line per `ARG`, so a new pin is wired up by adding one `NAME=VALUE` pair, and a Dockerfile listed but missing now fails loudly rather than letting `perl` warn and `git add` error out. A new `release_version_update_in_manifests` target covers the two manifests no `ARG` rewrite can reach: the rust crate's `[package] version` and the go module template's `grpc` / `protobuf` / `genproto` pins and `go` directive. The php, java and csharp manifests need nothing extra - they carry `@PLACEHOLDER@` tokens resolved from their Dockerfile `ARG`s at image-build time.
* `release_update_proto_compiler_dependency` fans out to the six new languages as well, and `update_proto_compiler_dependency.sh` no longer aborts on a client repo that has no node toolchain: the `Dockerfile.utils` `ENV NODE_VERSION` rewrite and the `package.json` dependency merge now key off a single `IS_NODE_FAMILY` definition instead of two separate language lists that could drift apart.

*****************

## Release ONDEWO Proto Compiler 5.14.0

### Bug Fixes

* Angular: a proto3 field declared `optional` can finally carry its zero value across the wire. `@ngx-grpc/protoc-gen-ng` generates the same code for `optional bool x = 5` and for plain `bool x = 5`: `refineValues` rewrites an unset field to the zero value (`_instance.x = _instance.x || false`) and the writer then skips that value (`if (_instance.x) { _writer.writeBool(5, _instance.x); }`). Explicit presence was therefore destroyed twice over, and `false` / `0` / `""` produced no bytes at all, so the server applied its own default instead of what the caller asked for - `optional bool resume_after_false_interruption` (vtsi) could not be set to `false` from Angular by any means, and `CallView.MINIMUM`, being enum value 0, was unrequestable on all six read RPCs. Since the generated code for the two cases is byte-identical, no pattern over the `.ts` can tell them apart, and rewriting both would be wire-breaking - a plain proto3 scalar must stay unwritten at its zero value. `compile-proto-2-stubs.sh` now records a `--descriptor_set_out` **before** it strips the `optional` keyword from the protos, which is the only moment `proto3_optional` still marks the presence-bearing fields, and the new `fix-proto3-optional-presence.ts` replays that set over the generated stubs: it deletes the `refineValues` coercion, so "the caller said nothing" survives as `undefined`, and turns the writer's truthiness test into a presence test (`!== undefined && !== null`) - for those fields and no others. The reader needs no edit of its own: its per-field branch already runs only when the field is on the wire, and the `refineValues` call at the end of it was the only thing collapsing presence, so an absent field now reads back as `undefined`. Message-typed `optional` fields are deliberately left alone (a message is either an object or absent, so the truthiness guard is already an exact presence test), and so are the declared TypeScript types, which never modelled presence in the first place and whose widening would break every consumer compiled with `strictNullChecks`. A message the descriptor knows and the stubs do not, or a generated shape a future protoc-gen-ng release changes, fails the build rather than silently shipping a client that drops values. It also closes a second, quieter half of the same defect: protoc-gen-ng models a 64-bit value as the STRING `'0'`, which is truthy, so an `optional int64` that nobody set was coerced by `refineValues` and then written to the wire as 0 on every message that carried one. Measured over the ondewo-vtsi API: 183 fields in 72 messages rewritten across 10 of 75 stub files, every other byte identical; of those 183, 177 could not transmit their zero value and 6 transmitted one nobody set.

*****************

## Release ONDEWO Proto Compiler 5.13.0

### Bug Fixes

* Angular: hand-written sources that live beside the generated stubs now reach the library's public surface. The generated `public-api.ts` listed only the proto stubs, so a client's hand-written `auth/` barrel (bearer credential + Keycloak token provider) was compiled but never bundled - `import { KeycloakTokenProvider } from "@ondewo/nlu-client-angular"` did not resolve for any consumer, and applications had to re-implement token acquisition and refresh themselves. `generate-public-api.sh` now star-exports the barrel when the source volume has one, looking for both layouts in use - `auth/index.ts` (nlu-client-angular) and `lib/auth/index.ts` (csi- and sip-client-angular, which keep it under the library source root). The import prefix follows the destination: `./auth` in the entry file `ng build` compiles, `./src/auth` in the copy written to the output volume one level above the mounted input directory, and no barrel line at all in the `npm/` copy, which holds the packaged output plus `api/` and no hand-written sources at any depth. A client with neither barrel is unaffected.
* Javascript: the generated `public-api.js` no longer star-exports itself, and no longer emits an export line for a *directory* whose name ends in `.js` (the scan had no `-type f`). It is created from the default file *before* the stub scan runs, so the scan picked it up and emitted `export * from './public-api';` into the webpack entry point - a circular self-reference. The entry file is now pruned from the scan, and the emitted specifiers lost a doubled `./` prefix (`'././api/…'` -> `'./api/…'`).
* Nodejs, Typescript: the client's hand-written `auth/` modules are re-exported from the generated `public-api.d.ts` / `public-api.js`. These targets keep hand-written sources at the *output* volume root, beside the generated barrels, rather than inside the mounted input directory the way Angular does, so the export is appended by a new `append-auth-exports.sh` after the output copy rather than by the barrel generator. Without it a client shipped `auth/` but nothing re-exported it, so `import { login } from "@ondewo/nlu-client-nodejs"` did not resolve and only a deep import into the module worked. Every non-spec module directly under `auth/` is exported once, keyed by basename so the `.ts` / `.js` / `.d.ts` spellings of one module collapse; re-running never duplicates a line, and a client without an `auth/` directory is untouched.
* Nodejs, Typescript: `append-auth-exports.sh` skips an `auth/` module whose basename contains a quote, backslash or space instead of emitting a syntactically broken export line that would take the whole barrel down with it.
* Nodejs, Typescript: the generated `public-api.d.ts` no longer breaks a consumer's build when two protos declare the same top-level symbol. This is the TS2308 ambiguity fixed for Angular in 5.12.0, ported to the remaining TypeScript-emitting targets: each duplicated symbol now also gets an explicit re-export bound to the first stub that declares it, which takes precedence over the star exports. The `.js` barrel is unaffected - protoc's closure output declares no `export` bindings to collide.

*****************

## Release ONDEWO Proto Compiler 5.12.0

### Bug Fixes

* Angular: the generated `public-api.ts` no longer breaks the library build when two protos declare the same top-level symbol. Protos in different packages may legitimately share a name (`ondewo.nlu` and `ondewo.s2t` both declare `ReasoningEffort`), but the barrel re-exported every stub with `export *` only, which makes such a name ambiguous and fails the build with TS2308. Each duplicated symbol now also gets an explicit re-export bound to the first stub that declares it, which takes precedence over the star exports. Both barrel generators are fixed - the one compiled by `ng build` and the copy shipped in `npm/` - via a shared `generate-public-api.sh`.

*****************

## Release ONDEWO Proto Compiler 5.11.0

### Improvements

* Angular, Nodejs, Javascript, Typescript: run the proto-compilation codegen non-interactively — dropped the `-it` flag from the `docker run` invocations in the example scripts and docs so they work in CI / non-TTY environments. Interactive `--entrypoint /bin/bash` debug commands keep `-it`.

*****************

## Release ONDEWO Proto Compiler 5.10.0

### Improvements

* Angular, Nodejs, Javascript, Typescript, Python: hardened all build and release shell scripts for cross-platform
  (Linux + macOS) portability — BSD/GNU-safe `sed -i.bak`, `find`, and `mktemp` usage, no `grep -P` /
  `realpath --relative-to` / `readlink -f`, guarded `cd`, quoted paths, and removal of `eval`
* Angular, Nodejs, Javascript, Typescript, Python: build and release scripts now fail loudly (`set -e`, explicit
  propagation) when a required input (protos source directory, `package.json`, README) is missing, instead of silently
  producing empty output
* Standardized Dockerfile hygiene: `COPY` instead of `ADD` for `image-data`, exec-form `ENTRYPOINT`, and removal of
  token baking from `Dockerfile.utils`
* Angular, Nodejs, Javascript, Typescript: upgraded Nodejs version to `NODE_VERSION=24.14.0`
* Added a host-side test suite (`shellcheck` gate + `bats`) and a GitHub Actions CI workflow running on an Ubuntu and
  macOS matrix; exposed locally via `make lint` / `make test`
* Angular, Nodejs, Javascript, Typescript, Python: upgraded Python to `PYTHON_VERSION=3.12`
* Python: moved the `python` and `Dockerfile.utils` images to the smaller `python:<version>-slim` base, and the node
  images to `node:<version>-slim`, dropping the explicit `-bookworm` distro suffix so images track Debian stable
* Angular, Nodejs, Javascript, Typescript: wrapped `npm install` in a 5-attempt retry loop (15s backoff) to ride out
  transient npm registry / network failures, mirroring the existing `wget` retry on the protoc download
* Javascript, Nodejs: merged redundant `npm install` layers into a single `RUN` per image
* `Makefile`: the release version-bump (`release_version_update_in_dockerfiles`) now also manages `Dockerfile.utils`'s
  `PYTHON_VERSION`, with matching `bats` coverage
* Upgraded pre-commit hooks to their latest versions and replaced the archived `pre-commit/mirrors-prettier` with the
  official prettier (`prettier@3.9.4`) consumed via a local `node` hook

### Bug Fixes

* Javascript: dropped the `@webpack-cli/init` dev dependency to unbreak the webpack bundling step
* Javascript: fixed an invalid global `npm install` flag combination in the `Dockerfile`
* Python: fixed proto discovery/anchoring and removed a dangling empty include-path segment in the `Makefile`

*****************

## Release ONDEWO Proto Compiler 5.9.0

### Improvements

* Angular, Nodejs, Javascript, Typescript: added wget retry mechanism (3 attempts with 5s delay using --tries and --waitretry flags) when downloading protoc binary to improve build reliability

### Bug Fixes

* Angular, Nodejs, Javascript, Typescript: added ca-certificates package to fix SSL certificate validation errors when downloading protoc binary
* Angular: copy generated api stubs directory to output volume so proto-generated TypeScript files (*.pb.ts,*.pbsc.ts, *.pbconf.ts) are available on the host after build
* Angular: generate public-api.d.ts from api stubs and include it along with api/ directory in the npm package folder
* Angular: fix api path nesting issue (api/api/) when copying stubs to output volume

*****************

## Release ONDEWO Proto Compiler 5.8.0

### Bug Fixes

* Angular: fixed if a variable in proto files is named optional `optional bool optional = 1`

*****************

## Release ONDEWO Proto Compiler 5.7.0

### Bug Fixes

* Angular: stabilized angular build via turning ng analytics off and setting CI to true:
  `ng analytics off && CI=true ng build --configuration production`

*****************

## Release ONDEWO Proto Compiler 5.6.0

### Improvements

* [OND221-2523] Angular: upgrade to angular 20
* [OND221-2523] Angular, Nodejs, Javascript, Typescript: upgraded Nodejs version to 22.18.0 LTS
* [OND221-2523] Angular, Nodejs, Javascript, Typescript: protoc compiler to `PROTOC_VERSION=32.0`

*****************

## Release ONDEWO Proto Compiler 5.5.3

### Bug Fixes

* python: upgrade to bookworm

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
