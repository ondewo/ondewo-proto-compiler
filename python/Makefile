IMAGE_NAME=ondewo-python-proto-compiler
INTERNAL_OUTPUT_DIR=/home/ondewo/ondewo-proto-compiler/output
INTERNAL_PROTO_DIR=/home/ondewo/ondewo-proto-compiler/protos

build:
	docker build -t ${IMAGE_NAME} .

OUTPUT_DIR=output
PROTO_DIR=ondewo
EXTRA_PROTO_DIR=googleapis/google
TARGET_DIR=
run:
	-mkdir ${OUTPUT_DIR}
	docker run \
		--user ${shell id -u}:${shell id -g} \
		-v ${shell pwd}/${OUTPUT_DIR}:/home/ondewo/ondewo-proto-compiler/output \
		-v ${shell pwd}/${PROTO_DIR}:/home/ondewo/ondewo-proto-compiler/protos/${shell basename ${PROTO_DIR}} \
		-v ${shell pwd}/${EXTRA_PROTO_DIR}:/home/ondewo/ondewo-proto-compiler/protos/${shell basename ${EXTRA_PROTO_DIR}} \
		-e INTERNAL_TARGET_PROTO_DIR=${TARGET_DIR} \
		${IMAGE_NAME}

generate_protos:
	# Note: the `find` expression contains a `?` to allow for an optional target directory to be passed
	#	If none is passed, the `/` will be ignored which is the default behaviour.
	for f in $$(find ${INTERNAL_PROTO_DIR} -path '${INTERNAL_PROTO_DIR}/${INTERNAL_TARGET_PROTO_DIR}?*.proto'); do \
		python -m grpc_tools.protoc \
			-I ${INTERNAL_PROTO_DIR} \
			--python_out=${INTERNAL_OUTPUT_DIR} \
			--mypy_out=${INTERNAL_OUTPUT_DIR} \
			--grpc_python_out=${INTERNAL_OUTPUT_DIR} \
			$$f; \
	done
