export

# =====================================================================================
# ondewo-proto-compiler - Makefile
#
# Single entry point for building the per-language proto-compiler docker images and for
# cutting a release. There is no long-running app here: each target either builds one of
# the language images (see `build*`) or drives a step of the release automation.
#
# Quick start:
#   make help                 # list every documented target
#   make makefile_chapters    # list the section headers below
#   make build                # build all five compiler images
#   make build_<lang>         # build a single image: angular | python | js | nodejs | typescript
#   make test                 # shellcheck gate + bats suite (no Docker required)
#
# Versioning: ONDEWO_PROTO_COMPILER_VERSION (below) is the single source of truth and MUST
# match the ONDEWO API in major and minor version. The release targets propagate it into
# every package.json and into the ARG lines of each Dockerfile - never edit those by hand.
#
# Overriding variables: pass on the command line, e.g. `make build NODE_VERSION=24.14.0`,
# or export in the environment. Credentials (GITHUB_GH_TOKEN, PYPI_*) are only ever read at
# runtime and must not be committed.
# =====================================================================================

# ---------------- BEFORE RELEASE ----------------
# 1 - Update Version Number
# 2 - Update RELEASE.md
# 3 - make update_setup
# -------------- Release Process Steps --------------
# 1 - Get Credentials from devops-accounts repo
# 2 - Create Release Branch and push
# 3 - Create Release Tag and push
# 4 - GitHub Release
# 5 - PyPI Release

########################################################
# 		Variables
########################################################

# Single source of truth for the release version. MUST match the ONDEWO API in major and
# minor version. Propagated into all package.json + Dockerfile ARGs by the release targets.
ONDEWO_PROTO_COMPILER_VERSION=5.9.0

# Toolchain versions baked into the docker images via each Dockerfile's ARG lines.
# Change here and run the release targets so every image stays in sync.
PYTHON_VERSION=3.9
NODE_VERSION=24.14.0
PROTOC_VERSION=32.0
GRPC_WEB_VERSION=1.5.0

# GitHub token for the release automation. Create one at https://github.com/settings/tokens
# (permissions matter). Passed at runtime only - never commit a real value.
GITHUB_GH_TOKEN?=ENTER_YOUR_TOKEN_HERE

# Release notes for the current version, sliced out of RELEASE.md for the GitHub release body.
CURRENT_RELEASE_NOTES=`cat RELEASE.md \
	| sed -n '/Release ONDEWO Proto Compiler ${ONDEWO_PROTO_COMPILER_VERSION}/,/\*\*/p'`

# GitHub repo, the devops-accounts credentials repo, and the utils image tag used by the release flow.
GH_REPO="https://github.com/ondewo/ondewo-proto-compiler"
DEVOPS_ACCOUNT_GIT="ondewo-devops-accounts"
DEVOPS_ACCOUNT_DIR="./${DEVOPS_ACCOUNT_GIT}"
IMAGE_UTILS_NAME=ondewo-proto-compiler-utils:${ONDEWO_PROTO_COMPILER_VERSION}

# `make` with no target prints the help listing.
.DEFAULT_GOAL := help


# Define colors globally (reused for [INFO]/[SUCCESS]/[WARN]/[ERROR] log lines in recipes)
BLUE   := \033[1;34m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
NC     := \033[0m

########################################################
#       ONDEWO Standard Make Targets
########################################################

setup_developer_environment_locally: install_python_requirements install_nvm install_precommit_hooks ## Sets up local development environment

install_nvm: ## Install NVM, node and npm (restart your terminal if node is not found afterwards)
	@curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
	@bash install_nvm.sh
	@node --version && npm --version || \
		echo "$(YELLOW)[WARN]$(NC) node/npm not on PATH yet - restart your terminal and verify with 'node --version'"

install_python_requirements: ## Installs python requirements flake8 and mypy
	pip install --no-cache-dir -r requirements.txt

install_precommit_hooks: ## Installs pre-commit hooks and sets them up for the ondewo-proto-compiler repo
	pip install pre-commit
	pre-commit install
	pre-commit install --hook-type commit-msg

precommit_hooks_run_all_files: ## Runs all pre-commit hooks on all files and not just the changed ones
	pre-commit run --all-files

help: ## Print usage info about help targets
	# (first comment after target starting with double hashes ##)
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-40s\033[0m %s\n", $$1, $$2}'

makefile_chapters: ## Shows all sections of Makefile
	@echo `cat Makefile| grep "########################################################" -A 1 | grep -v "########################################################"`

TEST: ## Diagnostics - report whether release credentials are set and print the current release notes
	@echo "GITHUB_GH_TOKEN is set: $(if $(GITHUB_GH_TOKEN),yes,no)"
	@echo "PYPI_USERNAME is set: $(if $(PYPI_USERNAME),yes,no)"
	@echo "PYPI_PASSWORD is set: $(if $(PYPI_PASSWORD),yes,no)"
	@printf '\n%s\n' "${CURRENT_RELEASE_NOTES}"

########################################################
#       Repo Specific Make Targets
########################################################

build: ## Build all proto compiler docker images (build-all.sh)
	sh build-all.sh

build_angular: ## Build the angular proto compiler docker image
	cd angular && sh build.sh

build_python: ## Build the python proto compiler docker image
	cd python && sh build.sh

build_js: ## Build the js proto compiler docker image
	cd js && sh build.sh

build_nodejs: ## Build the nodejs proto compiler docker image
	cd nodejs && sh build.sh

build_typescript: ## Build the typescript proto compiler docker image
	cd typescript && sh build.sh

########################################################
#       Tests & Linting
########################################################

lint: ## Run shellcheck over all tracked shell scripts
	shellcheck -x -S warning $$(git ls-files '*.sh' '*.bash' 'tests/helpers/bin/*')

test: lint ## Run the shellcheck gate and the bats test suite (no Docker required)
	bats tests/

########################################################
#		Release

release: release_version_update_in_dockerfiles release_version_update_in_packages_json_files create_release_branch create_release_tag build_and_release_to_github_via_docker release_update_proto_compiler_dependency ## Automate the entire release process
	@echo "Release Finished"

release_version_update_in_packages_json_files: ## Set ONDEWO_PROTO_COMPILER_VERSION in every package.json, then commit and push
	@for file in \
		angular/example/package.json \
		angular/image-data/package.json \
		js/image-data/default-lib-files/package.json \
		nodejs/example/package.json \
		nodejs/image-data/package.json \
		typescript/example/package.json \
		typescript/image-data/package.json ; do \
		echo "$(BLUE)[INFO]$(NC) Updating version in $$file to ${ONDEWO_PROTO_COMPILER_VERSION}"; \
		jq --arg version "${ONDEWO_PROTO_COMPILER_VERSION}" '.version = $$version' "$$file" > tmp.json && mv tmp.json "$$file"; \
		git add "$$file"; \
	done; \
	if ! git diff --cached --quiet; then \
		echo "$(BLUE)[INFO]$(NC) Committing and pushing changes..."; \
		git commit -m "Prepare release ${ONDEWO_PROTO_COMPILER_VERSION} and update version in package.json files"; \
		git push; \
		echo "$(GREEN)[SUCCESS]$(NC) Version updated and pushed successfully."; \
	else \
		echo "$(YELLOW)[NOOP]$(NC) No changes to commit."; \
	fi

release_version_update_in_dockerfiles: ## Update ARG versions in Dockerfiles
	@for file in \
		typescript/Dockerfile \
		nodejs/Dockerfile \
		python/Dockerfile \
		js/Dockerfile \
		angular/Dockerfile ; do \
		sed -i.bak "s/^ARG PYTHON_VERSION=.*/ARG PYTHON_VERSION=${PYTHON_VERSION}/" $$file; \
		sed -i.bak "s/^ARG NODE_VERSION=.*/ARG NODE_VERSION=${NODE_VERSION}/" $$file; \
		sed -i.bak "s/^ARG PROTOC_VERSION=.*/ARG PROTOC_VERSION=${PROTOC_VERSION}/" $$file; \
		sed -i.bak "s/^ARG GRPC_WEB_VERSION=.*/ARG GRPC_WEB_VERSION=${GRPC_WEB_VERSION}/" $$file; \
		rm -f $$file.bak; \
		echo "$(BLUE)[INFO]$(NC) Set versions in $$file"; \
		git add "$$file"; \
	done; \
	if ! git diff --cached --quiet; then \
		echo "$(BLUE)[INFO]$(NC) Committing and pushing Dockerfile updates..."; \
		git commit -m "Prepare release ${ONDEWO_PROTO_COMPILER_VERSION} and update Dockerfile ARGs"; \
		git push; \
		echo "$(GREEN)[SUCCESS]$(NC) Version updated and pushed successfully."; \
	else \
		echo "$(YELLOW)[NOOP]$(NC) No changes to commit."; \
	fi

# Fans out to one sub-target per language; each runs update_proto_compiler_dependency.sh
# for every ONDEWO client repo (nlu, s2t, t2s, sip, csi, vtsi, survey) to bump the pinned
# compiler dependency there. Invoke a single language directly for a targeted update.
release_update_proto_compiler_dependency: release_update_proto_compiler_dependency_angular release_update_proto_compiler_dependency_python release_update_proto_compiler_dependency_js release_update_proto_compiler_dependency_nodejs release_update_proto_compiler_dependency_typescript  ## Updates the proto compiler dependency in all submodules
	echo "$(GREEN)[SUCCESS]$(NC) Updating proto compiler dependency for all programming languages completed"

release_update_proto_compiler_dependency_angular: export PROGRAMMING_LANGUAGE=angular
release_update_proto_compiler_dependency_angular: ## Bump the compiler dependency in every angular client repo
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-nlu-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-s2t-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-t2s-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-sip-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-csi-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-vtsi-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-survey-client

release_update_proto_compiler_dependency_python: export PROGRAMMING_LANGUAGE=python
release_update_proto_compiler_dependency_python: ## Bump the compiler dependency in every python client repo
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-nlu-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-s2t-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-t2s-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-sip-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-csi-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-vtsi-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-survey-client

release_update_proto_compiler_dependency_js: export PROGRAMMING_LANGUAGE=js
release_update_proto_compiler_dependency_js: ## Bump the compiler dependency in every js client repo
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-nlu-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-s2t-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-t2s-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-sip-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-csi-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-vtsi-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-survey-client

release_update_proto_compiler_dependency_nodejs: export PROGRAMMING_LANGUAGE=nodejs
release_update_proto_compiler_dependency_nodejs: ## Bump the compiler dependency in every nodejs client repo
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-nlu-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-s2t-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-t2s-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-sip-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-csi-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-vtsi-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-survey-client

release_update_proto_compiler_dependency_typescript: export PROGRAMMING_LANGUAGE=typescript
release_update_proto_compiler_dependency_typescript: ## Bump the compiler dependency in every typescript client repo
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-nlu-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-s2t-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-t2s-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-sip-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-csi-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-vtsi-client
	sh update_proto_compiler_dependency.sh $(ONDEWO_PROTO_COMPILER_VERSION) $(PROGRAMMING_LANGUAGE) $(NODE_VERSION) ondewo-survey-client

create_release_branch: ## Create Release Branch and push it to origin
	git checkout -b "release/${ONDEWO_PROTO_COMPILER_VERSION}"
	git push -u origin "release/${ONDEWO_PROTO_COMPILER_VERSION}"

create_release_tag: ## Create Release Tag and push it to origin
	git tag -a ${ONDEWO_PROTO_COMPILER_VERSION} -m "release/${ONDEWO_PROTO_COMPILER_VERSION}"
	git push origin ${ONDEWO_PROTO_COMPILER_VERSION}

login_to_gh: ## Login to Github CLI with Access Token
	@if [ -z "${GITHUB_GH_TOKEN}" ] || [ "${GITHUB_GH_TOKEN}" = "ENTER_YOUR_TOKEN_HERE" ]; then \
		echo "$(RED)[ERROR]$(NC) GITHUB_GH_TOKEN is not set - create one at https://github.com/settings/tokens"; \
		exit 1; \
	fi
	@echo "${GITHUB_GH_TOKEN}" | gh auth login -p ssh --with-token

build_gh_release: ## Generate Github Release with CLI
	gh release create --repo $(GH_REPO) "$(ONDEWO_PROTO_COMPILER_VERSION)" -n "$(CURRENT_RELEASE_NOTES)" -t "Release ${ONDEWO_PROTO_COMPILER_VERSION}"

########################################################
#		GITHUB

build_and_release_to_github_via_docker: build_utils_docker_image release_to_github_via_docker_image  ## Release automation for building and releasing on GitHub via a docker image

build_utils_docker_image:  ## Build utils docker image
	docker build -f Dockerfile.utils -t ${IMAGE_UTILS_NAME} .

push_to_gh: login_to_gh build_gh_release ## Login to GitHub and publish the release (runs inside the utils image)
	@echo 'Released to Github'

release_to_github_via_docker_image:  ## Release to Github via docker
	@echo "$(BLUE)[INFO]$(NC) Releasing to GitHub via ${IMAGE_UTILS_NAME} ..."
	@docker run --rm \
		-e GITHUB_GH_TOKEN=${GITHUB_GH_TOKEN} \
		${IMAGE_UTILS_NAME} make push_to_gh

########################################################
#		DEVOPS-ACCOUNTS

ondewo_release: spc clone_devops_accounts run_release_with_devops ## Release with credentials from devops-accounts repo
	@rm -rf ${DEVOPS_ACCOUNT_GIT}

clone_devops_accounts: ## Clones devops-accounts repo
	if [ -d $(DEVOPS_ACCOUNT_GIT) ]; then rm -Rf $(DEVOPS_ACCOUNT_GIT); fi
	git clone git@bitbucket.org:ondewo/${DEVOPS_ACCOUNT_GIT}.git

run_release_with_devops: ## Read credentials from the cloned devops-accounts repo and run the full release
	$(eval info:= $(shell cat ${DEVOPS_ACCOUNT_DIR}/account_github.env | grep GITHUB_GH & cat ${DEVOPS_ACCOUNT_DIR}/account_pypi.env | grep PYPI_USERNAME & cat ${DEVOPS_ACCOUNT_DIR}/account_pypi.env | grep PYPI_PASSWORD))
	@make release $(info)

spc: ## Checks if the Release Branch and Tag already exist
	$(eval filtered_branches:= $(shell git branch --all | grep -E "(^|[ /])release/$(subst .,\.,${ONDEWO_PROTO_COMPILER_VERSION})$$"))
	$(eval filtered_tags:= $(shell git tag --list | grep -Fx "${ONDEWO_PROTO_COMPILER_VERSION}"))
	@if test "$(filtered_branches)" != ""; then echo "-- Test 1: Branch exists!!" && exit 1; else echo "-- Test 1: Branch is fine";fi
	@if test "$(filtered_tags)" != ""; then echo "-- Test 2: Tag exists!!" && exit 1; else echo "-- Test 2: Tag is fine";fi
