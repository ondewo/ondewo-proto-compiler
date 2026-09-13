IMAGE_NAME=ondewo-go-proto-compiler

build:
	docker build -t ${IMAGE_NAME} .

# PROTO_DIR / OUTPUT_DIR are relative to the CWD, because the mounts below are built as
# ${shell pwd}/${VAR} (same convention as python/Makefile). PROTO_DIR is mounted inside the input
# volume under its own basename, which is also what the entrypoint gets as <relative_protos_dir>.
# TARGET_DIR scopes the compilation to one sub-directory of the proto root; empty = every .proto
# below the root (the vendored google/ tree is always excluded - see image-data/compile-proto-2-stubs.sh).
# Unlike the other targets it is quoted below instead of just vanishing when empty: the go module
# path follows it as a third positional argument and must not slide into its place.
PROTO_DIR=example/protos
TARGET_DIR=
OUTPUT_DIR=example/lib
GO_MODULE_PATH=
run:
	# The go import path of every generated package is baked into the generated code by
	#	protoc-gen-go, so the module path is not optional here (the image can only fall back to a
	#	go.mod that lies inside the mounted input volume).
	@[ -n "${GO_MODULE_PATH}" ] || { echo "ERROR: GO_MODULE_PATH is required, e.g. 'make run GO_MODULE_PATH=github.com/ondewo/ondewo-nlu-client-go'" >&2; exit 1; }
	[ -d $(OUTPUT_DIR) ] || mkdir -p $(OUTPUT_DIR)
	# NOTE: no -it. A TTY-enabled container breaks every non-interactive caller with
	#	"cannot attach stdin to a TTY-enabled container because stdin is not a terminal".
	# No --user either: GOPATH=/go, the module cache and GOCACHE=/go/build-cache are root-owned
	#	inside the image, so `go build` has to run as root (like the node targets, unlike python).
	docker run \
		-v ${shell pwd}/${PROTO_DIR}:/input-volume/${shell basename ${PROTO_DIR}} \
		-v ${shell pwd}/${OUTPUT_DIR}:/output-volume \
		${IMAGE_NAME} ${shell basename ${PROTO_DIR}} "${TARGET_DIR}" "${GO_MODULE_PATH}"
