IMAGE_NAME=ondewo-cpp-proto-compiler

build:
	docker build -t ${IMAGE_NAME} .

# Directory mounted as /input-volume; PROTO_DIR/TARGET_DIR are interpreted INSIDE it.
INPUT_DIR=.
# Proto root, relative to INPUT_DIR (entrypoint argument 1).
PROTO_DIR=protos
# Sub-directory of the proto root to compile (entrypoint argument 2). "." means "all protos in
# the root"; it is spelled as a dot rather than left empty on purpose, because an empty word
# would collapse in the shell and LIBRARY_NAME would slide into argument 2's position.
TARGET_DIR=.
# CMake target / package / archive name (entrypoint argument 3).
LIBRARY_NAME=ondewo_grpc_client
# Directory mounted as /output-volume; receives the CMake install tree + the stub sources.
OUTPUT_DIR=lib

# No -it: it breaks every non-interactive caller ("cannot attach stdin to a TTY-enabled
# container because stdin is not a terminal"). No --user either: the scripts write into the
# root-owned /image-data tree inside the container, exactly like the node targets.
run:
	[ -d $(OUTPUT_DIR) ] || mkdir -p $(OUTPUT_DIR)
	docker run \
		-v ${shell pwd}/${INPUT_DIR}:/input-volume \
		-v ${shell pwd}/${OUTPUT_DIR}:/output-volume \
		${IMAGE_NAME} ${PROTO_DIR} $(if $(TARGET_DIR),$(TARGET_DIR),.) ${LIBRARY_NAME}
