IMAGE_NAME=ondewo-python-proto-compiler
INTERNAL_OUTPUT_DIR=/home/ondewo/ondewo-proto-compiler/output
INTERNAL_PROTO_DIR=/home/ondewo/ondewo-proto-compiler/protos

build:
	docker build -t ${IMAGE_NAME} .

# OUTPUT_DIR / PROTO_DIR / EXTRA_PROTO_DIR are relative to the CWD, because the mounts below are
# built as ${shell pwd}/${VAR}. EXTRA_PROTO_DIR is OPTIONAL (a proto root that vendors no
# dependency tree passes none) and is therefore mounted only when it is set: an empty value used
# to expand to `-v ${shell pwd}/:/home/ondewo/ondewo-proto-compiler/protos/`, which mounts the
# WHOLE working directory over the image's proto root, shadows the PROTO_DIR mount and sweeps
# every .proto in the tree into the compile set - while still exiting 0.
OUTPUT_DIR=output
PROTO_DIR=protos
EXTRA_PROTO_DIR=
TARGET_DIR=
EXTRA_PROTO_MOUNT=$(if $(EXTRA_PROTO_DIR),-v ${shell pwd}/${EXTRA_PROTO_DIR}:/home/ondewo/ondewo-proto-compiler/protos/${shell basename ${EXTRA_PROTO_DIR}})
run:
	@[ -n "${PROTO_DIR}" ] && [ -n "${OUTPUT_DIR}" ] || { echo "ERROR: PROTO_DIR and OUTPUT_DIR must not be empty - they are mounted as ${shell pwd}/<dir>" >&2; exit 1; }
	# A missing mount source is not an error docker reports: the daemon creates it as an empty
	#	ROOT-owned directory on the host, which then fails inside the container as
	#	"no .proto files found" and leaves a directory the caller cannot delete behind.
	@[ -d "${PROTO_DIR}" ] || { echo "ERROR: PROTO_DIR='${PROTO_DIR}' is not a directory (relative to ${shell pwd})" >&2; exit 1; }
	@[ -z "${EXTRA_PROTO_DIR}" ] || [ -d "${EXTRA_PROTO_DIR}" ] || { echo "ERROR: EXTRA_PROTO_DIR='${EXTRA_PROTO_DIR}' is not a directory (relative to ${shell pwd})" >&2; exit 1; }
	# Create the output dir as the CALLER, not as docker: the container runs as the caller's
	#	uid:gid below (unlike the node/go targets, nothing in this image needs root), so a
	#	root-owned auto-created mount point would be unwritable from inside it.
	[ -d $(OUTPUT_DIR) ] || mkdir -p $(OUTPUT_DIR)
	# NOTE: no -it. A TTY-enabled container breaks every non-interactive caller with
	#	"cannot attach stdin to a TTY-enabled container because stdin is not a terminal".
	docker run \
		--user ${shell id -u}:${shell id -g} \
		-v ${shell pwd}/${OUTPUT_DIR}:/home/ondewo/ondewo-proto-compiler/output \
		-v ${shell pwd}/${PROTO_DIR}:/home/ondewo/ondewo-proto-compiler/protos/${shell basename ${PROTO_DIR}} \
		${EXTRA_PROTO_MOUNT} \
		-e INTERNAL_TARGET_PROTO_DIR=${TARGET_DIR} \
		${IMAGE_NAME}

generate_protos:
	# Note: an optional target directory (INTERNAL_TARGET_PROTO_DIR) scopes compilation to a single
	#	proto sub-directory, anchored on a real `/` boundary; if none is passed, every .proto under
	#	the proto dir is compiled.
	# Candidates are matched by NAME (-path) and then filtered with `[ -f ]` in the loop, never
	#	with find's own `-type f` - the same filter every other target applies:
	#	 * `-type f` does not follow a symlink, so a .proto a client symlinked into its protos
	#	   dir was silently dropped from the compile set (measured: find -type f returns 1 of 2);
	#	   `[ -f ]` follows the link, so it is compiled like any other proto.
	#	 * the name alone is not enough either: a DIRECTORY named *.proto satisfies -path just as
	#	   well as a file does, and would be handed to protoc ("Is a directory") - or, on its own,
	#	   silently satisfy the no-protos guard below. It fails `[ -f ]` and is skipped.
	#	 * NOT `find -L`: -L makes find DESCEND into symlinked directories, where a link loop can
	#	   hang the run. Plain find never descends one, so a looping or dangling .proto link just
	#	   fails `[ -f ]` and is reported by name below.
	# The list is consumed with `while IFS= read -r`, never `for f in $$files`: an unquoted
	#	expansion word-splits a path containing a space AND glob-expands one containing [ ] * ?,
	#	which compiles the wrong file set (skipping the real proto) and still exits 0.
	target="$$INTERNAL_TARGET_PROTO_DIR"; \
	target="$${target%/}"; \
	if [ -n "$$target" ]; then \
		filter="${INTERNAL_PROTO_DIR}/$$target/*.proto"; \
	else \
		filter="${INTERNAL_PROTO_DIR}/*.proto"; \
	fi; \
	find "${INTERNAL_PROTO_DIR}" -path "$$filter" | { \
		count=0; \
		while IFS= read -r f; do \
			if [ ! -f "$$f" ]; then \
				if [ -L "$$f" ]; then echo "ERROR: the .proto symlink '$$f' does not resolve to a file - point it inside the mounted proto directory or materialise the file - exiting" >&2; exit 1; fi; \
				if [ -d "$$f" ]; then continue; fi; \
				echo "ERROR: '$$f' is not a readable .proto file - exiting" >&2; exit 1; \
			fi; \
			python -m grpc_tools.protoc \
				-I ${INTERNAL_PROTO_DIR} \
				--python_out=${INTERNAL_OUTPUT_DIR} \
				--mypy_out=${INTERNAL_OUTPUT_DIR} \
				--grpc_python_out=${INTERNAL_OUTPUT_DIR} \
				"$$f" || exit 1; \
			rel="$${f#${INTERNAL_PROTO_DIR}/}"; \
			stub="${INTERNAL_OUTPUT_DIR}/$${rel%.proto}_pb2.py"; \
			[ -f "$$stub" ] || { echo "ERROR: grpc_tools.protoc reported success for '$$rel' but produced no '$$stub' - there is nothing to build a library from - exiting" >&2; exit 1; }; \
			count=$$((count + 1)); \
		done; \
		[ "$$count" -gt 0 ] || { echo "ERROR: no .proto files found for '$$filter'" >&2; exit 1; }; \
		echo "files generated by proto compilation: $$count"; \
	}
