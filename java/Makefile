IMAGE_NAME=ondewo-java-proto-compiler

build:
	docker build -t ${IMAGE_NAME} .

# PROTO_DIR / OUTPUT_DIR are relative to the CWD, because the mounts below are built as
# ${shell pwd}/${VAR} (same convention as python/Makefile).
# TARGET_DIR scopes the compilation to one sub-directory of the proto root; empty = every
# .proto below the root (the vendored google/ tree is always excluded - see
# image-data/compile-proto-2-stubs.sh). It is passed LAST so an empty value simply vanishes.
PROTO_DIR=example/protos
OUTPUT_DIR=example/lib
TARGET_DIR=
run:
	[ -d $(OUTPUT_DIR) ] || mkdir -p $(OUTPUT_DIR)
	docker run \
		-v ${shell pwd}/${PROTO_DIR}:/input-volume/protos \
		-v ${shell pwd}/${OUTPUT_DIR}:/output-volume \
		${IMAGE_NAME} protos ${TARGET_DIR}
