# Tests

Fast, host-side tests for the shell / Make / Docker build tooling. **No Docker
build is required** — the scripts' external tools (`docker`, `git`, `python`,
`protoc`, `composer`, `php`, `go`, `cargo`, `cmake`, `mvn`, `dotnet`, …) are
replaced by PATH-mocks that log their arguments and return controllable exit
codes, so the tests exercise the scripts' own logic (error propagation, argument
handling, path construction, version bumping) in milliseconds.

Scope is all **eleven** language targets: the original `angular`, `js`,
`nodejs`, `typescript`, `python` plus the six added in 5.15.0 — `php`, `go`,
`rust`, `cpp`, `java`, `csharp`.

## Running

```bash
make lint    # shellcheck over all tracked shell scripts
make test    # shellcheck gate + the whole bats suite
bats tests/  # just the bats suite
```

Requires [`shellcheck`](https://www.shellcheck.net/) and
[`bats`](https://github.com/bats-core/bats-core) on `PATH`
(`npm install -g bats`; `apt-get install shellcheck` or `conda install -c conda-forge shellcheck`;
on macOS `brew install shellcheck bats-core`).

The suite runs on **Linux and macOS** — CI (`.github/workflows/ci.yml`) executes
it on both `ubuntu-latest` and `macos-latest`, so scripts and tests must stick
to portable constructs (`sed -i.bak` instead of bare `sed -i`, no `grep -P`,
`[[:space:]]` instead of `\s`, explicit `find <path>`, `mktemp` always with an
`XXXXXX` template, bash-3.2-compatible syntax — macOS ships bash 3.2).

## Layout

| Path | Purpose |
| --- | --- |
| `helpers/setup.bash` | `common_setup`/`common_teardown`: sandbox tmp dir, prepend the mock bins to `PATH`, and `scrub_toolchain_env` (wipe the ambient toolchain environment — see below) |
| `helpers/bin/` | PATH-mock executables that log argv and honour env-controlled exit codes: `git`, `docker`, `python`, `npm`, `protoc`, `grpc_tools_node_protoc`, plus the new targets' toolchains `composer`, `php`, `go`, `cargo`, `cmake`, `mvn`, `dotnet`, `grpc_cpp_plugin` |
| `fixtures/client-repos/` | client-repo skeletons (`package.json` / `Dockerfile.utils`, plus a deliberately corrupt one) for the release-automation tests |
| `fixtures/presence/` | REAL protoc / protoc-gen-ng output for the angular proto3 explicit-presence codemod (`regenerate.sh` rebuilds it) |
| `*.bats` | the test files; a target whose coverage is a whole pipeline of its own gets a `<lang>_target.bats` (`php`, `go`, `rust`, `cpp`, `java`, `csharp`), the rest are grouped by the script or artifact under test |

## What each file proves

| File | Under test | Key findings covered |
| --- | --- | --- |
| `shellcheck.bats` | every tracked shell script (`git ls-files '*.sh' '*.bash' 'tests/helpers/bin/*'`, so the six new targets' scripts **and** the PATH-mocks are linted too) | static gate is clean; no missing shebangs (SC2148) / unguarded `cd` (SC2164) |
| `portability_static.bats` | every tracked `*.sh` outside `tests/` | the BSD/macOS-hostile constructs the `macos-latest` leg would fail on: `grep -P`, `sed -r`, bare `sed -i`, `readlink -f`, `find -printf`, a `find` without an explicit start path, `realpath --relative-to`, template-less `mktemp`, GNU-only `stat`/`date` flags, `md5sum`/`sha*sum`/`tac`, `sort -V` / `xargs -r` / `head -n -N` / `cp --parents`, `xargs -I … bash -c`, `echo -e`, `\s` in a regex, and bash-4-only syntax. Like `shellcheck.bats` it uses the **real** `git`, and a first case fails if the discovery ever goes empty, so the scans cannot pass vacuously |
| `update_proto_compiler_dependency.bats` | release automation | 4-arg guard (rel-1), nodejs is bumped (rel-2), corrupt source fails loudly (rel-3), happy-path dependency + `NODE_VERSION` rewrite |
| `dependency_resolver.bats` | `js/image-data/dependecy-resolver.sh` (the file `rust` and `cpp` vendor verbatim) | transitive resolution, `google/protobuf` exclusion, loud failure (js-3), correct path handling (js-6) |
| `orchestrators.bats` | `build-all.sh`, `*/build.sh` | a failing `docker build` propagates instead of exiting 0 (orch-1, orch-2) — asserted for **every** target, not a sampled few: each `build.sh` tags its own image and builds its own directory (`$(dirname "$0")`, not the caller's CWD) exactly once, `build-all.sh` builds the whole discovered language set in its documented order with no image built twice, a failure in any one language makes it the last build attempted, and a missing language directory is a loud break rather than a silently skipped image. Discovery walks the filesystem, not the mock `git` |
| `python_makefile.bats` | `python/Makefile generate_protos` | protoc failure aborts (mk-1), target dir anchored (mk-2), empty match fails (mk-3), no empty `-I` segment (mk-8) |
| `orchestrators_e2e.bats` | `compile-proto-2-<lang>.sh` (the four node targets) | full pipeline on the host via env-overridden container paths: stub generation, entry points, lib packaging, copy-back; loud failure on missing inputs |
| `proto_stub_deps.bats` | `compile-proto-2-stubs.sh` (the four node targets) | empty deps file does not abort, non-empty triggers dependency pass, direct protoc call (no eval), find-based no-protos guard |
| `php_target.bats` | the whole `php/` target — orchestrator, `compile-proto-2-stubs.sh`, `compile-stubs-2-lib.sh`, `make-lib-entry-point.sh`, `build.sh`, `example/run-compile.sh` | the mounted input is never mutated and the stubs stage in `generated-src/`, so a client's own PSR-4 `src/` can never be merged into the compiler-owned tree; `src/` and `vendor/` are wiped per run while hand-written `auth/` survives; `composer validate` → `update` → `dump-autoload` really runs, offline, inside the staged `lib/`; the `php` heredoc stub-load verification runs and its failure aborts before anything ships; the manifest merge and the `auth/` classmap registration are idempotent; `google/protobuf/**` is not regenerated |
| `go_target.bats` | the whole `go/` target | one `M<proto>=<import path>;<pkg>` mapping per non-google proto, built from the module path (argument 3, else the input volume's `go.mod`) — mapped over the whole root, compiled only over the selected sub-tree; `paths=source_relative`; `google/**` neither compiled nor mapped; there is no barrel, so `go.mod` rendered from `go.mod.template` is what makes the directories importable and a hand-maintained one is kept; trailing slashes normalised on all three arguments; a failing `go build` aborts before the output volume is touched |
| `rust_target.bats` | the whole `rust/` target | protoc runs **exactly once**, with `--prost_out` before `--tonic_out` into the *same* directory (splitting or reordering silently drops every gRPC client); `src/api` is entirely generated — never seeded from the input volume, wiped in the output volume, while hand-written modules beside it survive; the crate manifest template comes from the input volume when present, else from the image default, and the packaged `<name>-<version>.crate` is named after it; the offline dependency pre-flight rejects anything the image did not pre-warm *before* cargo is invoked (a shared name prefix does not satisfy a dep, a `[dependencies.<name>]` sub-table is checked too); `SKIP_CARGO_BUILD=1` degrades to stub generation; an ambient `CARGO_TARGET_DIR` cannot redirect the build or the artifact lookup |
| `cpp_target.bats` | the whole `cpp/` target | the full `compile-proto-2-cpp.sh` → stubs → `public-api.h` → cmake configure/`--build`/`--install` → copy-back chain, each cmake call made exactly once with the injected `-D` values; build and install trees live outside the copied source tree and stale ones are wiped first; the library-name and dotted-version validations fire before anything is generated; `public-api.h` includes every generated header, sorted and `api/`-relative, and an input-volume one is used verbatim; the cleanup is narrow enough that hand-written files in the output volume survive and an `api/` carried in from the input volume is neither compiled nor copied out; a missing `grpc_cpp_plugin` aborts before cmake |
| `java_target.bats` | the whole `java/` target | the Dialogflow-inherited `java_package` rewrite happens on the temp copy and leaves no `.bak`; the stale sweep drops only this run's LEAF package dirs and this artifact's jars, so a hand-written sibling package and a foreign jar survive; the unscoped multi-tree guard (and its trailing-slash bypass); the vendored `google/` tree is an import root, never a compilation target; every pom placeholder is substituted from the arguments and the image ENV, and each missing toolchain pin is named; `mvn` runs `--offline --batch-mode` against `-Dmaven.repo.local`, and `mvn` exiting 0 without a jar is caught rather than shipped |
| `csharp_target.bats` | the whole `csharp/` target | the documented output layout (`api/`, `artifacts/<tfm>/`, `nupkg/`, `<PackageId>.csproj`) and what is deliberately **not** copied out (`bin/`, `obj/`, `README.md`, `nuget.config`); stale `api/`/`artifacts/`/`nupkg/` cleanup versus the output volume's own `bin/`/`obj/`/`README.md`; the output-volume-inside-the-input-volume example layout run twice; package-id validation and the `$OndewoPackageId` fallback; all five required MSBuild properties validated up front (empty as well as unset); the `nuget.config` offline-feed placeholder substituted and never copied out; `restore`/`build`/`pack` as three offline calls, each failure aborting with the script's own error |
| `client_wrappers.bats` | `js/image-data/generate-client-wrappers.sh` | wrapper appended per `*Client` with namespace substituted; no-op without service stubs |
| `lib_entry_points.bats` | `js` / `nodejs` / `typescript` `make-lib-entry-point.sh` | no self-export, single-dot specifiers, `node_modules`/webpack config skipped, a *directory* named `*.js` is not exported, TS2308 duplicate disambiguation |
| `public_api_barrel.bats` | `angular/image-data/generate-public-api.sh` | star-exports every stub, TS2308 disambiguation, the hand-written `auth/` (and `lib/auth/`) barrel, the import-prefix argument and the literal `none` used for `npm/` |
| `auth_exports.bats` | `nodejs` / `typescript` `append-auth-exports.sh` | re-export from both barrels, `.ts`/`.js`/`.d.ts` spellings collapsed, specs skipped, idempotent, a client without `auth/` untouched |
| `proto3_optional_presence.bats` | `angular/image-data/fix-proto3-optional-presence.ts` | the descriptor-driven codemod rewrites exactly the `proto3_optional` fields, leaves plain scalars and the reader alone, and fails loudly on anything it cannot match |
| `release_targets.bats` | root `Makefile` version-bump targets | every `ARG`/`package.json` version rewritten across **all eleven** staged Dockerfiles (a listed-but-missing Dockerfile now fails loudly instead of letting `perl` warn and `git add` error out), no sed `.bak` leftovers (BSD-portable `-i.bak`), commit/push only when staged changes exist |
| `examples.bats` | `*/example/run-compile.sh` | well-formed, quoted `-v` mounts (js-7); no doubled path on absolute invocation (node-3) — and, over every target that ships an example, exactly one `docker run` mounting the script's own dir in and its own `lib/` out, no unquoted `-v` operand, a sibling `run-compile.bat` + `build.bat`, and **no `-it` on the codegen run** (it fails every non-interactive caller with "cannot attach stdin to a TTY-enabled container"; `-it` belongs only on the `--entrypoint /bin/bash` debug branch) |
| `dockerfile_static.bats` | Dockerfiles + Makefile + `build-all.sh` / `build-all.bat` | `NODE_VERSION` consistency (mk-6), exec-form `ENTRYPOINT` (py-1) — and, now that there are eleven targets, the wiring that keeps one from silently escaping: every declared `ARG` is release-managed by `DOCKERFILE_ARGS`, every production Dockerfile is in `DOCKERFILES`, each image declares exactly one `ENTRYPOINT` and it runs *that* target's orchestrator, and the language set agrees across disk, Makefile, `build-all.sh`, `build-all.bat` and the `build_<lang>` targets. Discovery walks the repo tree rather than a hard-coded language list (via the filesystem, **not** `git ls-files` — `common_setup` puts the mock `git` first on `PATH` and it answers `ls-files` with silence, which would turn every loop into a vacuous pass), so a twelfth target is covered the day its directory lands |
| `install_nvm.bats` | `install_nvm.sh` | the pinned node version is installed **and** activated; a missing nvm fails instead of silently succeeding |
| `windows_wrappers.bats` | `build-all.bat`, every `<lang>/build.bat`, every `<lang>/example/run-compile.bat` | the one slice of the tooling no behavioural test can drive (`cmd.exe` exists on neither CI leg), so it is pinned statically: one-to-one symmetry with the `.sh` scripts they mirror and identical image tag / entrypoint arguments; every invocation anchored on `%~dp0` and guarded by `if errorlevel 1` + `exit /b 1` (orch-1/orch-2 in Windows clothing), failure messages on `1>&2`; no `-it` on a codegen `docker run` — kept only on the `--entrypoint /bin/bash` debug line; no `%~dp0\` double backslash; quoted `-v` mounts and build contexts; `mkdir` guarded by `if not exist` (cmd sets `ERRORLEVEL 1` on an existing dir); LF line endings, pure ASCII (`[OK]`, not the `.sh` banners' ✅) and a trailing newline. The custom detectors are themselves run against synthetic bad wrappers (win-25…win-30) so a detector that stopped matching cannot make the file pass vacuously |

### Known-bug skips

Nine cases across the six new targets are `skip`ped with a `BUG: …` reason
instead of being softened or deleted. Each asserts the behaviour the script
*should* have and names the line that gets it wrong, so the case turns back into
a real assertion the moment the production script is fixed — `grep -n 'skip' *_target.bats`
is the current list. They fall into four groups:

- a `find … -iname "*.proto"` with **no `-type f`**, so a *directory* named
  `*.proto` satisfies the no-protos guard (`cpp`, `csharp`, `go`);
- `google/**` filtered out of the *imports* but not out of the **entry set**, so
  the well-known types are handed to protoc anyway (`cpp`, `csharp`, `php`);
- `java`, where a trailing slash on argument 1 bypasses the multi-tree guard,
  and a `java/` directory in the input volume contaminates the library;
- `go`, where a kept hand-maintained `go.mod` still gets the image's `go.sum`
  written next to it — the pair has to be written together or not at all.

## Mock knobs (env vars)

Each mock models its real tool closely enough that a target's whole
`compile-proto-2-<lang>.sh` → `compile-proto-2-stubs.sh` → `compile-stubs-2-lib.sh`
pipeline runs on the host — which is what the six `<lang>_target.bats` files
drive. It enforces the preconditions the real tool enforces (a manifest in the
CWD), and it materialises the artifacts the next step looks for, so a missing
one surfaces as the script's own named error rather than as a bare non-zero
exit. The `*_FAIL_MATCH` / `*_FAIL_RC` pairs are how each target's
failure-propagation cases are written: fail one stage by substring and assert
the orchestrator exits non-zero with its own message on stderr.

- `git`: `REPO_FIXTURE` (skeleton to "clone"), `CAPTURE_DIR` (where `git add` snapshots staged files so they survive the script's temp-dir cleanup), `GIT_DIFF_RC`, `GIT_MOCK_LOG`.
- `docker`: `FAIL_BUILD_MATCH` / `FAIL_BUILD_RC` (force a `docker build` to fail), `DOCKER_MOCK_LOG`.
- `python`: `PY_FAIL_MATCH` / `PY_FAIL_RC` (fail on a matching argument), `PY_MOCK_LOG`.
- `protoc` / `grpc_tools_node_protoc`: `PROTOC_MOCK_LOG` (shared); fail with "Missing input file." when no `.proto` arg is passed, and materialise a dummy stub file per `*_out` flag so downstream packaging steps see generated output. The `protoc` mock's per-flag branches are listed under [What the protoc mock emits](#what-the-protoc-mock-emits); the node one only knows `--grpc_out` (⇒ `mock_grpc_pb.js`) and the `mock_pb.js` default, which is all the node targets call it with.
- `npm`: `NPM_MOCK_LOG`, `NPM_MOCK_RC`; `npm run build` emulates the ng-packagr build output dir (`src/lib` in an angular workspace, else `./lib`).
- `composer`: `COMPOSER_MOCK_LOG`, `COMPOSER_FAIL_MATCH` / `COMPOSER_FAIL_RC`. Subcommand-aware: `validate` fails when the CWD has no `composer.json` (like the real tool), `update`/`install` write `composer.lock` + `vendor/autoload.php` + `vendor/composer/{autoload_classmap.php,installed.json}`, `dump-autoload` re-writes the classmap.
- `php`: `PHP_MOCK_LOG` (argv), `PHP_MOCK_STDIN_LOG` (the heredoc script it was fed), `PHP_FAIL_MATCH` / `PHP_FAIL_RC`, `PHP_MOCK_RC`. Models the `php <<'PHP' … PHP` stub-load verification at the end of `php/image-data/compile-stubs-2-lib.sh`: it drains **and records** the heredoc so a test can prove the verification really ran, and `PHP_MOCK_RC` makes that verification fail. Guarded on "no arguments **and** stdin is not a terminal", so it can never block the suite.
- `go`: `GO_MOCK_LOG`, `GO_FAIL_MATCH` / `GO_FAIL_RC`. A library `go build ./...` emits no artifact, so nothing is materialised; what *is* modelled is the precondition the real tool enforces — `go: go.mod file not found …` when the CWD has no `go.mod`.
- `cargo`: `CARGO_MOCK_LOG`, `CARGO_FAIL_MATCH` / `CARGO_FAIL_RC`. Reads crate name/version out of the `[package]` table of the CWD's `Cargo.toml`, so the artifact is named after the manifest protoc actually generated: `build` writes `$CARGO_TARGET_DIR/<profile>/lib<name>.rlib`, `package` writes `$CARGO_TARGET_DIR/package/<name>-<version>.crate` (plus its staging dir), which is exactly what `compile-stubs-2-lib.sh` globs for. Errors 101 without a `Cargo.toml`.
- `cmake`: `CMAKE_MOCK_LOG`, `CMAKE_FAIL_MATCH` / `CMAKE_FAIL_RC`. Three-mode, mirroring the cpp target's three calls. *configure* parses `-S` / `-B` / `-D…` and **persists** them (including `CMAKE_HOME_DIRECTORY`) in `<build>/CMakeCache.txt`, erroring when `-S` holds no `CMakeLists.txt`; `--build` writes `<build>/lib<name>.a`; `--install` — which is handed nothing but the build directory — reads `CMAKE_INSTALL_PREFIX` / `ONDEWO_LIBRARY_NAME` / `ONDEWO_LIBRARY_VERSION` back out of that cache and materialises `include/<name>/public-api.h` + one flattened `*.pb.h` per generated header, `lib/lib<name>.a`, and `lib/cmake/<name>/{-config,-config-version,-targets,-targets-release}.cmake`. An explicit `--prefix` wins over the cache.
- `mvn`: `MVN_MOCK_LOG`, `MVN_FAIL_MATCH` / `MVN_FAIL_RC`. Resolves the pom from `-f`/`--file` (else `./pom.xml`), packages only on a `package`/`install`/`deploy`/`verify` goal, reads the project's own first `<artifactId>`/`<version>` and drops `target/<artifactId>-<version>.jar` + `-sources.jar` next to the pom — `compile-stubs-2-lib.sh` aborts when `target/` holds no `*.jar`.
- `dotnet`: `DOTNET_MOCK_LOG`, `DOTNET_FAIL_MATCH` / `DOTNET_FAIL_RC`. Verb-aware: `restore` writes `obj/project.assets.json`, `build` writes `bin/Release/<tfm>/<PackageId>.{dll,pdb,xml}` (the csharp script aborts when `bin/Release` is missing), `pack -o DIR` writes `DIR/<PackageId>.<version>.{nupkg,snupkg}`. `PackageId` is the csproj basename; tfm and version resolve `$OndewoTargetFramework` / `$OndewoPackageVersion` first, then a *literal* `<TargetFramework>` / `<Version>` in the csproj (the `$(Property)` indirection the shipped template uses is skipped), then `net8.0` / `1.0.0`.
- `grpc_cpp_plugin`: `GRPC_CPP_PLUGIN_MOCK_LOG`, `GRPC_CPP_PLUGIN_MOCK_RC`. Never exec'd by the scripts — protoc runs it, and the protoc mock emits the `.grpc.pb.*` pair itself — but `cpp/image-data/compile-proto-2-stubs.sh` guards codegen with `command -v "$GRPC_CPP_PLUGIN"` and aborts without it, so an executable of this name has to be on `PATH`; point the script at it with `GRPC_CPP_PLUGIN=grpc_cpp_plugin`. It deliberately never reads stdin: the real plugin consumes a `CodeGeneratorRequest` from it, nothing here writes one, and a blocking read would hang the suite.

### What the protoc mock emits

One dummy file per generated artifact, into the directory named by the flag
(both `--x_out=DIR` and `--x_out=opts:DIR` are understood):

| Flag | Files written below the `_out` directory |
| --- | --- |
| `--descriptor_set_out` | a FILE, not a directory: the smallest well-formed `FileDescriptorSet`, marking no field — what the angular presence codemod inspects |
| `--ng_out` | `mock_pb.ts` |
| `--ts_out` | `mock_pb.d.ts` |
| `--grpc-web_out` | `mock_grpc_web_pb.js` + `mock_grpc_web_pb.d.ts` |
| `--php_out` | `GPBMetadata/Mock/Test.php` + `Mock/TestMessage.php`, laid out by PHP namespace; `Google/Protobuf` is deliberately never written (the well-known types ship inside the `google/protobuf` composer package) |
| `--go_out` / `--go-grpc_out` | `mock.pb.go` / `mock_grpc.pb.go` — flat, so assert on the suffixes and on the `--go_opt=M<proto>=<import>;<pkg>` mappings in the log, not on a mirrored tree |
| `--prost_out` / `--tonic_out` | `mock.package.rs` / `mock.package.tonic.rs` (rust generates per proto *package*, not per file) |
| `--prost-crate_out` | the include file named by `--prost-crate_opt=include_file=…` (default `src/api/mod.rs`, directories created) plus a `Cargo.toml` **copied from** the `gen_crate=<template>` path, so the real `[dependencies]` table reaches the crate and rust's offline dependency pre-flight is genuinely exercisable |
| `--cpp_out` | `mock.pb.h` + `mock.pb.cc` |
| `--java_out` / `--grpc-java_out` | `com/ondewo/mock/Test.java` + `TestOrBuilder.java` / `com/ondewo/mock/TestGrpc.java` — nested in the `java_package` dirs on purpose: the java orchestrator sweeps stale stubs per LEAF package directory, and flat output at the source root would skip that sweep entirely |
| `--csharp_out` | `Ondewo/Mock/Test.cs`, nested by C# namespace (which is what `base_namespace=` does) |
| `--grpc_out` | flavour-dependent — see below |
| anything else | `mock_pb.js` |

`--grpc_out` is spelled identically by **three** targets that mean three
different plugins: php (`grpc_php_plugin` ⇒ `Mock/TestServiceClient.php`), cpp
(`grpc_cpp_plugin` ⇒ `mock.grpc.pb.h` + `mock.grpc.pb.cc`) and csharp
(`grpc_csharp_plugin` ⇒ `Ondewo/Mock/TestGrpc.cs`, passed in the
`--grpc_out=base_namespace=:DIR` opts form). Real protoc tells them apart by the
`--plugin=protoc-gen-grpc=<binary>` it is handed; resolving that in the mock
would mean exec'ing a plugin the host does not have. A **pre-pass over the whole
argv**, before any file is written, therefore takes the flavour from the
companion language flag of the same invocation — `--php_out` ⇒ php, `--cpp_out`
⇒ cpp, `--csharp_out` ⇒ csharp. That signal is unambiguous (no target passes two
of them) and stable (each target makes exactly one protoc call, which is the
unit of disambiguation), and because it is a pre-pass it is **order-independent**.
With no companion flag the branch falls back to the historical `mock_pb.js`, so
any pre-existing caller keeps byte-identical behaviour. The same pre-pass
collects `--prost-crate_opt`'s `include_file=` / `gen_crate=` values, which
appear *after* `--prost-crate_out` in the argv.

### The scrubbed environment

`common_setup` calls `scrub_toolchain_env`, which unsets every variable in the
`CARGO_` `RUST` `GO` `COMPOSER_` `PHP_` `MAVEN_` `M2_` `JAVA_` `NUGET_`
`DOTNET_` `MSBUILD` `CMAKE_` `GRPC_` `PROTOC` `ONDEWO_` `Ondewo` prefix
namespaces, plus the script knobs that match no prefix: `IMAGE_DATA_DIRECTORY`
`INPUT_VOLUME_FS` `OUTPUT_VOLUME_FS` `TEMP_SRC_DIRECTORY` `DEFAULT_FILES_DIR`
`BUILD_DIRECTORY` `INSTALL_DIRECTORY` `CRATE_DIRECTORY` `DIST_DIRECTORY`
`SKIP_CARGO_BUILD`. A developer's or CI runner's ambient `CARGO_HOME`, `GOPATH`,
`NUGET_PACKAGES`, `MAVEN_OPTS`, `JAVA_HOME`, … would otherwise redirect a build
out of the sandbox and make a test's outcome depend on the machine it runs on —
and an ambient container-path override would point a pipeline's guarded
`rm -rf` (and its output) at a real directory instead of the sandbox. Names
matching `*_MOCK_LOG` / `*_MOCK_RC` / `*_MOCK_STDIN_LOG` / `*_FAIL_MATCH` /
`*_FAIL_RC` are exempt, so the mock layer's own knobs survive and there is no
ordering footgun.

**Consequence for test authors:** every *script* knob a case needs —
`GRPC_CPP_PLUGIN`, `ONDEWO_CLIENT_VERSION`, `GRPC_JAVA_VERSION` /
`PROTOBUF_JAVA_VERSION` / `GOOGLE_COMMON_PROTOS_VERSION` /
`MAVEN_SOURCE_PLUGIN_VERSION` / `JAVA_RELEASE`, `OndewoTargetFramework` /
`OndewoPackageVersion` / `GoogleProtobufVersion` / `GrpcDotnetVersion` /
`GoogleApiCommonProtosVersion`, `NUGET_OFFLINE_FEED`, `CARGO_REGISTRY_HOME`,
`SKIP_CARGO_BUILD`, `MAVEN_REPO_LOCAL` — must be exported **after**
`common_setup`, never before.

### Container paths the scripts expose

Every orchestrator reads its container paths from the environment with the
container path as the default — `IMAGE_DATA_DIRECTORY`, `INPUT_VOLUME_FS`,
`OUTPUT_VOLUME_FS`, `TEMP_SRC_DIRECTORY` — and that is what lets the suite run
them on the host against sandbox directories. The six new targets follow the
same rule for every extra path or binary that would otherwise be unreachable
off-image:

| Target | Additional overrides |
| --- | --- |
| `php` | `GRPC_PHP_PLUGIN` (never exec'd, only passed to protoc as `--plugin=protoc-gen-grpc=`), `COMPOSER_DISABLE_NETWORK` |
| `go` | none beyond the four — the module path is positional argument 3 |
| `rust` | `CRATE_DIRECTORY`, `DIST_DIRECTORY`, `PROTOC`, `CARGO`, `CARGO_REGISTRY_HOME` (the pre-warmed registry the offline pre-flight checks), `SKIP_CARGO_BUILD=1` (degrade to stub generation only), `DEFAULT_FILES_DIR` in `make-lib-entry-point.sh`. `CARGO_TARGET_DIR` is deliberately **not** honoured from the environment — it is derived and exported so an ambient value cannot redirect the build or the `*.crate` lookup |
| `cpp` | `BUILD_DIRECTORY`, `INSTALL_DIRECTORY` (both outside the copied source tree, and exported so `compile-stubs-2-lib.sh` resolves the same paths), `GRPC_CPP_PLUGIN` (guarded with `command -v`, so a PATH mock satisfies it), `ONDEWO_CLIENT_VERSION` (validated as dotted numeric), `CMAKE_BUILD_PARALLEL_LEVEL`, `DEFAULT_FILES_DIR` in `make-lib-entry-point.sh` |
| `java` | `MAVEN_REPO_LOCAL`, `PROTOC_GEN_GRPC_JAVA`, `ONDEWO_PROTO_COMPILER_VERSION`, and the pom pins `GRPC_JAVA_VERSION` / `PROTOBUF_JAVA_VERSION` / `GOOGLE_COMMON_PROTOS_VERSION` / `MAVEN_SOURCE_PLUGIN_VERSION` / `JAVA_RELEASE` (`make-lib-entry-point.sh`, the pom renderer, fails loudly if any is empty) |
| `csharp` | `NUGET_OFFLINE_FEED`, `GRPC_CSHARP_PLUGIN`, `OndewoPackageId` (the fallback for positional argument 3), and the five MSBuild properties the orchestrator **requires** in the environment and aborts without: `OndewoTargetFramework`, `OndewoPackageVersion`, `GoogleProtobufVersion`, `GrpcDotnetVersion`, `GoogleApiCommonProtosVersion` (the image sets them from its `ARG` lines — and `scrub_toolchain_env` removes them, so a case has to export them itself). `OndewoProtosDir` is *derived* from argument 1 and exported, not read |

## Measured coverage

The suite's line coverage of the six new targets' `image-data/` scripts was measured by
running it under `BASH_ENV` + a `PS4` xtrace capture (`BASH_XTRACEFD` to a log), attributing
the traced sandbox copies back to the repo sources by basename. The unit is the **logical
command**, not the physical line: a command continued over several lines — by a trailing
backslash or an unterminated quote such as a multi-line `jq` program — is reported by bash
exactly once, and *which* line it reports differs by construct (a backslash continuation is
logged at head+1, a multi-line quoted command at head).

Result: **1216 of 1217 logical commands (99.9%)** — `php`, `go`, `java` and `csharp` at 100%,
`rust` and `cpp` at 99.6%.

The single uncovered command is `IS_EXCLUDED=""` in `{rust,cpp}/image-data/dependecy-resolver.sh`,
inside `if [ -z "$EXCLUDE_REGEX" ]`. It is **unreachable through every production path**: the
only entry point, `echoProtoDependencies()`, hardcodes a non-empty `"google/protobuf/"` regex.
The branch is inherited verbatim from the pre-existing `js/image-data/dependecy-resolver.sh`
and is left alone rather than covered by a contrived direct call to the inner function.

`build.sh` and `example/run-compile.sh` are excluded from the figure — they are `#!/bin/sh`,
and the `dash` that runs them on Linux ignores `BASH_ENV`, so the harness cannot see them.
They are covered behaviourally by `orchestrators.bats` and `examples.bats` instead.

The harness is a throwaway diagnostic, not part of `make test`; there is no `kcov`/`bashcov`
dependency in CI.

## Out of scope (needs a real Docker build)

Actual code generation and package building — `protoc` / `ng` / `webpack`, and
for the new targets `composer update`, `go build`, `cargo build`, the CMake
configure/compile/install cycle, `mvn package` and `dotnet build`/`pack` —
generated-stub correctness, the pre-warmed offline caches actually resolving
every dependency, byte-level idempotency of real generated output across two
container runs (the *layout* of a second run is covered by the per-target
cases), and npm-install reproducibility are **integration** concerns. Run them
with an end-to-end `make build_<lang>` against a sample proto tree —
intentionally not part of the fast unit gate.

The Windows wrappers (`build.bat`, `example/run-compile.bat`, `build-all.bat`)
are likewise never executed: `cmd.exe` exists on neither CI leg.
`windows_wrappers.bats` pins them statically instead — symmetry with the `.sh`
scripts, error propagation, argument drift and the cmd-specific footguns — but
their actual runtime behaviour on Windows stays untested here.
