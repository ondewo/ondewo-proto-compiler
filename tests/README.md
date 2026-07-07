# Tests

Fast, host-side tests for the shell / Make / Docker build tooling. **No Docker
build is required** — the scripts' external tools (`docker`, `git`, `python`,
`protoc`, …) are replaced by PATH-mocks that log their arguments and return
controllable exit codes, so the tests exercise the scripts' own logic (error
propagation, argument handling, path construction, version bumping) in
milliseconds.

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
`[[:space:]]` instead of `\s`, explicit `find <path>`, bash-3.2-compatible
syntax — macOS ships bash 3.2).

## Layout

| Path | Purpose |
| --- | --- |
| `helpers/setup.bash` | `common_setup`/`common_teardown`: sandbox tmp dir + prepend the mock bins to `PATH` |
| `helpers/bin/` | PATH-mock executables (`git`, `docker`, `python`, `npm`, `protoc`, `grpc_tools_node_protoc`) that log argv and honour env-controlled exit codes |
| `fixtures/` | static fixtures (client-repo skeletons with `package.json` / `Dockerfile.utils`) |
| `*.bats` | the test files |

## What each file proves

| File | Under test | Key findings covered |
| --- | --- | --- |
| `shellcheck.bats` | every tracked script | static gate is clean; no missing shebangs (SC2148) / unguarded `cd` (SC2164) |
| `update_proto_compiler_dependency.bats` | release automation | 4-arg guard (rel-1), nodejs is bumped (rel-2), corrupt source fails loudly (rel-3), happy-path dependency + `NODE_VERSION` rewrite |
| `dependency_resolver.bats` | `js/image-data/dependecy-resolver.sh` | transitive resolution, `google/protobuf` exclusion, loud failure (js-3), correct path handling (js-6) |
| `orchestrators.bats` | `build-all.sh`, `*/build.sh` | a failing `docker build` now propagates instead of exiting 0 (orch-1, orch-2) |
| `python_makefile.bats` | `python/Makefile generate_protos` | protoc failure aborts (mk-1), target dir anchored (mk-2), empty match fails (mk-3), no empty `-I` segment (mk-8) |
| `orchestrators_e2e.bats` | `compile-proto-2-<lang>.sh` (all four) | full pipeline on the host via env-overridden container paths: stub generation, entry points, lib packaging, copy-back; loud failure on missing inputs |
| `proto_stub_deps.bats` | `compile-proto-2-stubs.sh` (all four) | empty deps file does not abort, non-empty triggers dependency pass, direct protoc call (no eval), find-based no-protos guard |
| `client_wrappers.bats` | `js/image-data/generate-client-wrappers.sh` | wrapper appended per `*Client` with namespace substituted; no-op without service stubs |
| `release_targets.bats` | root `Makefile` version-bump targets | every `ARG`/`package.json` version rewritten, no sed `.bak` leftovers (BSD-portable `-i.bak`), commit/push only when staged changes exist |
| `examples.bats` | `*/example/run-compile.sh` | well-formed, quoted `-v` mounts (js-7); no doubled path on absolute invocation (node-3) |
| `dockerfile_static.bats` | Dockerfiles + Makefile | `NODE_VERSION` consistency (mk-6), exec-form `ENTRYPOINT` (py-1), no invalid npm flags / `ADD` wildcard |

## Mock knobs (env vars)

- `git`: `REPO_FIXTURE` (skeleton to "clone"), `CAPTURE_DIR` (where `git add` snapshots staged files so they survive the script's temp-dir cleanup), `GIT_DIFF_RC`, `GIT_MOCK_LOG`.
- `docker`: `FAIL_BUILD_MATCH` / `FAIL_BUILD_RC` (force a `docker build` to fail), `DOCKER_MOCK_LOG`.
- `python`: `PY_FAIL_MATCH` / `PY_FAIL_RC` (fail on a matching argument), `PY_MOCK_LOG`.
- `protoc` / `grpc_tools_node_protoc`: `PROTOC_MOCK_LOG` (shared); fail with "Missing input file." when no `.proto` arg is passed, and materialise a dummy stub file per `*_out` flag so downstream packaging steps see generated output.
- `npm`: `NPM_MOCK_LOG`, `NPM_MOCK_RC`; `npm run build` emulates the ng-packagr build output dir (`src/lib` in an angular workspace, else `./lib`).

The orchestrator scripts accept `IMAGE_DATA_DIRECTORY`, `INPUT_VOLUME_FS`,
`OUTPUT_VOLUME_FS` (and `TEMP_SRC_DIRECTORY` for js) as env overrides of their
container paths — that is what lets `orchestrators_e2e.bats` run them on the
host against sandbox directories.

## Out of scope (needs a real Docker build)

Actual `protoc` / `ng` / `webpack` code generation, generated-stub correctness,
idempotency across two container runs, and npm-install reproducibility are
**integration** concerns. Run them with an end-to-end `make build_<lang>` against
a sample proto tree — intentionally not part of the fast unit gate.
