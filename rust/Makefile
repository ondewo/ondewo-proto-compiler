IMAGE_NAME=ondewo-rust-proto-compiler

build:
	docker build -t ${IMAGE_NAME} .

# INPUT_DIR is the directory mounted at /input-volume; PROTO_DIR and TARGET_DIR are the two
# positional entrypoint arguments and are therefore relative to INPUT_DIR, not to the CWD.
# TARGET_DIR is optional: empty means "every .proto under PROTO_DIR".
# All *_DIR variables used for a mount are built as ${shell pwd}/${VAR} and must stay
# relative to the CWD (same contract as python/Makefile).
INPUT_DIR=.
PROTO_DIR=protos
TARGET_DIR=
OUTPUT_DIR=lib
run:
	[ -d $(OUTPUT_DIR) ] || mkdir -p $(OUTPUT_DIR)
	# NOTE: no -it. A TTY-enabled container breaks every non-interactive caller with
	#	"cannot attach stdin to a TTY-enabled container because stdin is not a terminal".
	# --user keeps the generated crate (src/, Cargo.lock, crate-dist/) owned by the caller;
	#	the image chmods its working dirs a+w so this works.
	docker run \
		--user ${shell id -u}:${shell id -g} \
		-v ${shell pwd}/${INPUT_DIR}:/input-volume \
		-v ${shell pwd}/${OUTPUT_DIR}:/output-volume \
		${IMAGE_NAME} ${PROTO_DIR} ${TARGET_DIR}
