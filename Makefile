export

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

# MUST BE THE SAME AS API in Mayor and Minor Version Number
ONDEWO_PROTO_COMPILER_VERSION=4.5.0

# You need to setup an access token at https://github.com/settings/tokens - permissions are important
GITHUB_GH_TOKEN?=ENTER_YOUR_TOKEN_HERE

CURRENT_RELEASE_NOTES=`cat RELEASE.md \
	| sed -n '/Release ONDEWO Proto Compiler ${ONDEWO_PROTO_COMPILER_VERSION}/,/\*\*/p'`

GH_REPO="https://github.com/ondewo/ondewo-proto-compiler"
DEVOPS_ACCOUNT_GIT="ondewo-devops-accounts"
DEVOPS_ACCOUNT_DIR="./${DEVOPS_ACCOUNT_GIT}"
IMAGE_UTILS_NAME=ondewo-proto-compiler-utils:${ONDEWO_PROTO_COMPILER_VERSION}
.DEFAULT_GOAL := help

########################################################
#       ONDEWO Standard Make Targets
########################################################

setup_developer_environment_locally: install_python_requirements install_nvm install_precommit_hooks ## Sets up local development environment !! Forcefully closes current terminal

install_nvm: ## Install NVM, node and npm !! Forcefully closes current terminal
	@curl https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
	@sh install_nvm.sh
	$(eval PID:=$(shell ps -ft $(ps | tail -1 | cut -c 8-13) | head -2 | tail -1 | cut -c 1-8))
	@node --version & npm --version || (kill -KILL ${PID})

install_python_requirements: ## Installs python requirements flak8 and mypy
	pip install -r requirements.txt

install_precommit_hooks: ## Installs pre-commit hooks and sets them up for the ondewo-proto-compiler repo
	pip install pre-commit
	pre-commit install
	pre-commit install --hook-type commit-msg

precommit_hooks_run_all_files: ## Runs all pre-commit hooks on all files and not just the changed ones
	pre-commit run --all-file

help: ## Print usage info about help targets
	# (first comment after target starting with double hashes ##)
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-40s\033[0m %s\n", $$1, $$2}'

makefile_chapters: ## Shows all sections of Makefile
	@echo `cat Makefile| grep "########################################################" -A 1 | grep -v "########################################################"`

TEST:
	@echo ${GITHUB_GH_TOKEN}
	@echo ${CURRENT_RELEASE_NOTES}

########################################################
#       Repo Specific Make Targets
########################################################

build:
	sh build-all.sh

build_angular:
	cd angular && sh build.sh

build_python:
	cd python && sh build.sh

build_js:
	cd js && sh build.sh

build_nodejs:
	cd nodejs && sh build.sh

build_typescript:
	cd typescript && sh build.sh

########################################################
#		Release

release: create_release_branch create_release_tag build_and_release_to_github_via_docker  ## Automate the entire release process
	@echo "Release Finished"

create_release_branch: ## Create Release Branch and push it to origin
	git checkout -b "release/${ONDEWO_PROTO_COMPILER_VERSION}"
	git push -u origin "release/${ONDEWO_PROTO_COMPILER_VERSION}"

create_release_tag: ## Create Release Tag and push it to origin
	git tag -a ${ONDEWO_PROTO_COMPILER_VERSION} -m "release/${ONDEWO_PROTO_COMPILER_VERSION}"
	git push origin ${ONDEWO_PROTO_COMPILER_VERSION}

login_to_gh: ## Login to Github CLI with Access Token
	echo $(GITHUB_GH_TOKEN) | gh auth login -p ssh --with-token

build_gh_release: ## Generate Github Release with CLI
	gh release create --repo $(GH_REPO) "$(ONDEWO_PROTO_COMPILER_VERSION)" -n "$(CURRENT_RELEASE_NOTES)" -t "Release ${ONDEWO_PROTO_COMPILER_VERSION}"

GENERIC_CLIENT?=
RELEASEMD?=
GENERIC_RELEASE_NOTES="\n***************** \n\\\#\\\# Release ONDEWO Proto Compiler REPONAME Client ${ONDEWO_PROTO_COMPILER_VERSION} \n \
	\n\\\#\\\#\\\# Improvements \n \
	* Tracking API Version [${ONDEWO_PROTO_COMPILER_VERSION}](https://github.com/ondewo/ondewo-proto-compiler/releases/tag/${ONDEWO_PROTO_COMPILER_VERSION}) ( [Documentation](https://ondewo.github.io/ondewo-proto-compiler/) ) \n"

# Change Version Number and RELEASE NOTES
	cd ${REPO_DIR} && sed -i -e '/Release History/r ../temp-notes' ${RELEASEMD}
	cd ${REPO_DIR} && head -20 ${RELEASEMD}
	cd ${REPO_DIR} && sed -i -e 's/ONDEWO_PROTO_COMPILER_VERSION.*=.*[0-9]*.[0-9]*.[0-9]/ONDEWO_PROTO_COMPILER_VERSION = ${ONDEWO_PROTO_COMPILER_VERSION}/' Makefile

# Build new code
	make -C ${REPO_DIR} ondewo_release | tee build_log_${REPO_NAME}.txt
	make -C ${REPO_DIR} TEST
# Remove everything from Release
	sudo rm -rf ${REPO_DIR}
	rm -f temp-notes

########################################################
#		GITHUB

build_and_release_to_github_via_docker: build_utils_docker_image release_to_github_via_docker_image  ## Release automation for building and releasing on GitHub via a docker image

build_utils_docker_image:  ## Build utils docker image
	docker build -f Dockerfile.utils -t ${IMAGE_UTILS_NAME} .

push_to_gh: login_to_gh build_gh_release
	@echo 'Released to Github'

release_to_github_via_docker_image:  ## Release to Github via docker
	docker run --rm \
		-e GITHUB_GH_TOKEN=${GITHUB_GH_TOKEN} \
		${IMAGE_UTILS_NAME} make push_to_gh

########################################################
#		DEVOPS-ACCOUNTS

ondewo_release: spc clone_devops_accounts run_release_with_devops ## Release with credentials from devops-accounts repo
	@rm -rf ${DEVOPS_ACCOUNT_GIT}

clone_devops_accounts: ## Clones devops-accounts repo
	if [ -d $(DEVOPS_ACCOUNT_GIT) ]; then rm -Rf $(DEVOPS_ACCOUNT_GIT); fi
	git clone git@bitbucket.org:ondewo/${DEVOPS_ACCOUNT_GIT}.git

run_release_with_devops:
	$(eval info:= $(shell cat ${DEVOPS_ACCOUNT_DIR}/account_github.env | grep GITHUB_GH & cat ${DEVOPS_ACCOUNT_DIR}/account_pypi.env | grep PYPI_USERNAME & cat ${DEVOPS_ACCOUNT_DIR}/account_pypi.env | grep PYPI_PASSWORD))
	make release $(info)

spc: ## Checks if the Release Branch and Tag already exist
	$(eval filtered_branches:= $(shell git branch --all | grep "release/${ONDEWO_PROTO_COMPILER_VERSION}"))
	$(eval filtered_tags:= $(shell git tag --list | grep "${ONDEWO_PROTO_COMPILER_VERSION}"))
	@if test "$(filtered_branches)" != ""; then echo "-- Test 1: Branch exists!!" & exit 1; else echo "-- Test 1: Branch is fine";fi
	@if test "$(filtered_tags)" != ""; then echo "-- Test 2: Tag exists!!" & exit 1; else echo "-- Test 2: Tag is fine";fi
