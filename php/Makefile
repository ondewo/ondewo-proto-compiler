IMAGE_NAME=ondewo-php-proto-compiler

build:
	docker build -t ${IMAGE_NAME} .

# NOTE: PROTO_DIR / OUTPUT_DIR are RELATIVE to the current working directory - the mounts below are
#	built as ${shell pwd}/${VAR}, exactly like python/Makefile, so an absolute path would produce a
#	doubled mount source. PROTO_DIR is mounted under the image's input volume as its own basename,
#	which is then passed to the entrypoint as <relative_protos_dir>.
#	TARGET_DIR is the optional <target_subdir> that scopes generation to one sub-directory of the
#	proto root; empty means "compile every .proto below the root".
PROTO_DIR=example/protos
TARGET_DIR=
OUTPUT_DIR=output
run:
	[ -d $(OUTPUT_DIR) ] || mkdir -p $(OUTPUT_DIR)
	docker run \
		-v ${shell pwd}/${PROTO_DIR}:/input-volume/${shell basename ${PROTO_DIR}} \
		-v ${shell pwd}/${OUTPUT_DIR}:/output-volume \
		${IMAGE_NAME} ${shell basename ${PROTO_DIR}} ${TARGET_DIR}
