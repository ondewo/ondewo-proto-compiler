# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

`ondewo-proto-compiler` is a collection of Docker images that turn protocol buffer definitions (`.proto`) into
installable gRPC client packages for several target platforms. There is no long-running application here — each target
is a Dockerfile plus a thin shell wrapper, and the whole thing is orchestrated by a `Makefile`.

- **Targets:** `angular/`, `js/`, `nodejs/`, `typescript/`, `python/`. Each directory holds a `Dockerfile`, a
  `build.sh`, and (except `python/`) an `example/` and `image-data/` used by the compiler image.
- **Build entrypoints:** `build-all.sh` builds every image; each `<lang>/build.sh` runs a single
  `docker build ... "$(dirname "$0")"`. The `Makefile` exposes these as `make build` / `make build_<lang>`.
- **Versioning:** `ONDEWO_PROTO_COMPILER_VERSION` in the `Makefile` is the single source of truth. It **must match the
  ONDEWO API in major and minor version**. The release targets propagate it into every `package.json` and into the
  `ARG` lines of each `Dockerfile`.
- **Release:** driven entirely by `Makefile` targets (`release`, `ondewo_release`) and
  `update_proto_compiler_dependency.sh`, which bumps the compiler dependency across all client repos. See `RELEASE.md`.

## Working Principles

Behavioral guidelines to reduce common mistakes. They bias toward caution over speed; for trivial tasks, use judgment.

### Think before coding

Don't assume. Don't hide confusion. Surface tradeoffs.

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### Simplicity first

Minimum code that solves the problem. Nothing speculative.

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### Surgical changes

Touch only what you must. Clean up only your own mess.

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that _your_ changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the user's request.

### Goal-driven execution

Define success criteria. Loop until verified.

Transform tasks into verifiable goals:

- "Add a target" → "Run the build and confirm the image is produced / stubs are generated"
- "Fix the build" → "Reproduce the failing `build.sh`, then make it pass"
- "Bump a version" → "Grep for the old version, confirm every occurrence is updated consistently"

For multi-step tasks, state a brief plan:

```text
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

These guidelines are working if: fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and
clarifying questions come before implementation rather than after mistakes.

## Common Commands

Run from the repo root. `make help` prints all documented targets.

```bash
make build              # build all compiler images (build-all.sh)
make build_angular      # build a single target: angular | python | js | nodejs | typescript
bash <lang>/build.sh    # equivalent single-image build (docker build)

make setup_developer_environment_locally   # python reqs + nvm + pre-commit hooks
make install_precommit_hooks               # pre-commit install (+ commit-msg hook)
make precommit_hooks_run_all_files         # run all hooks on all files

make lint    # shellcheck over all tracked shell scripts
make test    # shellcheck gate + the bats test suite (no Docker required)
```

Compiling `.proto` files with a built image (see `README.md` and the `<lang>/example/run-compile.sh` scripts):

```bash
docker run -it -v $FILEDIRECTORY:/input-volume -v $FILEDIRECTORY/lib:/output-volume \
  ondewo-<lang>-proto-compiler protos
```

## Shell Scripts & Console Output

The scripts here are POSIX `sh` (`#!/bin/sh`), invoked with `bash`/`sh` from the `Makefile`. Match the existing style:

- **Resolve paths relative to the script, not the caller's CWD:** use `"$(dirname "$0")"` /
  `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` rather than assuming the working directory.
- **Stay portable across GNU (Linux) and BSD (macOS) userlands** — CI runs the suite on both. Concretely:
  `sed -i.bak '…' file && rm -f file.bak` instead of bare `sed -i`; no `grep -P` (use `sed -n 's|…|\1|p'` to extract);
  `[[:space:]]` instead of `\s`; always give `find` an explicit start path; count with `… | grep -c . || true` rather
  than `wc -l` (BSD `wc` pads with spaces); no bash-4-only syntax (macOS ships bash 3.2, e.g. no `${*: -1}`, no
  associative arrays).
- **Banner-style progress output.** Bracket a notable operation with an opening and a closing `echo` separated by a
  ruled line, and mark completion with a ✅. Keep the separator characters consistent with the surrounding file:

  ```sh
  echo "---------------------------------------------------------------"
  echo "Angular: Starting .proto to grpc client stubs compilation ..."
  echo "---------------------------------------------------------------"

  docker build --no-cache -t ondewo-angular-proto-compiler:latest "$(dirname "$0")"

  echo "---------------------------------------------------------------"
  echo "✅ Angular: Done .proto to grpc client stubs compilation"
  echo "---------------------------------------------------------------"
  ```

- **`Makefile` conventions:** document targets with a trailing `## comment` (surfaced by `make help`), group them under
  the existing `####` chapter banners, and reuse the defined color variables (`$(BLUE)`, `$(GREEN)`, …) for `[INFO]` /
  `[SUCCESS]` messages instead of hard-coding escape codes.
- **`Dockerfile` versions** are set through `ARG` lines (`PYTHON_VERSION`, `NODE_VERSION`, `PROTOC_VERSION`,
  `GRPC_WEB_VERSION`). Change them via the `Makefile` release targets, not by hand, so all images stay in sync.

## Testing

`make test` runs two layers, neither of which needs a Docker build (see `tests/README.md`):

- **`shellcheck` gate** (`make lint`) over every tracked shell script, wired as a `.pre-commit-config.yaml` hook and a
  GitHub Actions job (`.github/workflows/ci.yml`, a Linux **and** macOS matrix). Keep it clean at `-S warning`. Where a
  variable holds a space-separated **list** meant to word-split (e.g. proto files passed to `protoc`), leave it
  unquoted and annotate with `# shellcheck disable=SC2086  # intentional word splitting …` rather than quoting it.
- **`bats` suite** under `tests/`, which drives the scripts' logic with PATH-mock
  `docker`/`git`/`python`/`npm`/`protoc`/`grpc_tools_node_protoc` (in `tests/helpers/bin/`) and fixtures, so
  error-propagation, argument handling, the full orchestrator pipelines (via the `IMAGE_DATA_DIRECTORY` /
  `INPUT_VOLUME_FS` / `OUTPUT_VOLUME_FS` env overrides), and the release version-bumps are all exercised without
  images. When you change a script's behaviour, update or add the matching `*.bats` case.

Anything that needs real `protoc`/`ng`/`webpack` code generation is an integration concern — run it with an end-to-end
`make build_<lang>`, not the fast unit gate.

## Downstream Client SDKs & End-to-End Generation

The images built here are consumed by five sibling client-SDK repos at `~/ondewo/ondewo-nlu-client-<lang>` (`python`,
`angular`, `typescript`, `js`, `nodejs`). Each client **vendors this repo as a git submodule** (`ondewo-proto-compiler/`,
pinned to a release commit/tag) and vendors the proto source as a second submodule, `ondewo-nlu-api/` (top-level dirs:
`ondewo/` = the ~19 service protos to compile, `google/` = well-known / API imports). The api submodule sits at
`ondewo-nlu-api/` for python and at `src/ondewo-nlu-api/` for the node clients.

### How a client generates stubs

Generation always runs the fixed image tag `ondewo-<lang>-proto-compiler:latest`. A client's `build_compiler` rebuilds
that tag from its submodule, but **the tag is the only contract** — so to test your *working-tree* compiler against a
client, just `docker build -t ondewo-<lang>-proto-compiler:latest <lang>` from this repo (no submodule bump needed) and
run the client's generate step.

- **python** — `make generate_ondewo_protos` → `make -f ondewo-proto-compiler/python/Makefile run
  PROTO_DIR=ondewo-nlu-api/ondewo/ EXTRA_PROTO_DIR=ondewo-nlu-api/google/ TARGET_DIR=ondewo OUTPUT_DIR=.`. The `run`
  target `docker run`s with `--user $(id -u):$(id -g)` (output is user-owned), mounts each `*_DIR` under the image's
  `protos/<basename>` + `output`, and passes `INTERNAL_TARGET_PROTO_DIR`. Mounts are built as `${shell pwd}/${VAR}`, so
  those vars must be **relative to CWD**. Entry `make generate_protos` runs `python -m grpc_tools.protoc`, emitting
  `_pb2.py` + `_pb2_grpc.py` + `.pyi` (⇒ **3 files per proto**).
- **angular / typescript / nodejs** — `src/package.json` `build`/`generate` script:
  `docker run -it -v ${PWD}:/input-volume -v ${PWD}/..:/output-volume ondewo-<lang>-proto-compiler ondewo-nlu-api ondewo`
  (args = `<relative_protos_dir> <target_subdir>`; output volume = the client **repo root**). Yields a full library
  (`api/`, `public-api.*`, compiled `.ts`/`.js`, `npm/`, sometimes an installed `node_modules/`).
- **js** — different arg/volume shape:
  `docker run -it -v ${PWD}:/input-volume -v ${PWD}/../api:/output-volume ondewo-js-proto-compiler ondewo-nlu-api ondewo-nlu-api ondewo`
  (args = `<lib_entry_name> <relative_protos_dir> <target_subdir>`). Output is a **single webpack bundle** (`<name>.js`
  + `.min.js` + `.map`) — a low file count is correct here, not a failure.

### Image / compile-script internals (`<lang>/image-data/compile-proto-2-<lang>.sh`, baked into the image)

- Each script **copies `/input-volume` into an internal temp dir** (`/image-data/src` or `/temp_src`) and compiles
  there, so the **mounted input is never mutated**; output is written only to `/output-volume`. Paths are env-overridable
  (`INPUT_VOLUME_FS` / `OUTPUT_VOLUME_FS` / `IMAGE_DATA_DIRECTORY` / `TEMP_SRC_DIRECTORY`) — that is how the bats suite
  drives them without Docker.
- Node scripts write under root-owned `/image-data`, so their containers **must run as root** (no `--user`); only the
  python `run` target uses `--user`. Some node scripts wipe parts of the output volume (e.g. angular `rm -rf npm
  package.json …`), so pointing `/output-volume` at a real repo root deletes + regenerates files in place.

### Safe end-to-end verification recipe

To confirm a compiler change generates valid client stubs **without dirtying any client repo**:

1. `docker build -t ondewo-<lang>-proto-compiler:latest <lang>` for each target from this repo.
2. Replay each client's exact `docker run` **but drop `-it`** and **redirect `/output-volume` to a throwaway temp dir**,
   feeding the real client `src` / `ondewo-nlu-api` as input. Client trees stay pristine (confirm with
   `git -C <client> status --porcelain`).
3. Assert on content, not just exit 0: python ⇒ `3 × proto_count` files that also `python -m compileall` inside the
   image; node ⇒ `api/` + `public-api.*`; js ⇒ webpack "compiled successfully" + the bundle files.

### Handy facts

- Base images use the distro-agnostic **slim** tags — `python:<v>-slim` and `node:<v>-slim` — deliberately dropping the
  explicit `-bookworm` so images track Debian stable. If you ever re-pin the distro, note the suffix order differs:
  python is `<v>-slim-bookworm` but node is `<v>-bookworm-slim` (there is no `node:<v>-slim-bookworm`).
- Docker does **not** variable-substitute `RUN` lines (only `ADD`/`COPY`/`ENV`/`FROM`/…), so a shell loop var like `$i`
  in a `RUN` is safe; declared `ARG`/`ENV` values are injected as env vars into the `RUN` shell.
- Generation needs **no network** once the image is built (node deps are `npm install`-ed at image-build time).

## Git Commits

- **Never include Claude as author or co-author** in commit messages, PR descriptions, or any other text. Do not add
  `Co-Authored-By: Claude…` trailers, "Generated with Claude Code" footers, or any similar attribution.
- The user's own git author identity (already configured in git) is the only identity that should appear on commits.
- This rule overrides the default Claude Code commit-template guidance.
- **Never prepend the JIRA ticket ID** (e.g. `[OND211-2418]`) to the commit subject yourself. The `giticket` pre-commit
  hook reads the ticket from the branch name and prepends `[<ticket>] ` automatically. Branch names match
  `(feature|bugfix|support|hotfix)/<TICKET>-…` **or** a bare `<TICKET>-…` (the prefix is optional), where `<TICKET>`
  looks like `OND211-2418`. Writing the prefix manually produces a duplicate like `[OND211-2418] [OND211-2418] feat: …`.
  Write the subject as plain Conventional Commits (`feat: …`, `fix(scope): …`, `docs: …`) and let the hook add the
  prefix on commit.

## General Principles

- Follow existing patterns before introducing new abstractions.
- Keep changes minimal and consistent with surrounding code.
- Keep the five language targets symmetrical — a change to one target's `Dockerfile`/`build.sh` usually needs the
  equivalent change in the others.
- Validate inputs early with descriptive, context-rich error messages.
- Prettier (`.prettierrc`: 2-space indent, single quotes, semicolons, 120 print width) formats `js/ts/json/…`; keep
  edits compatible so the pre-commit hook stays a no-op.
- End edited Markdown and YAML files with a trailing newline.
