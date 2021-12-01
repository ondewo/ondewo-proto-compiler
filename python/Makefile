IMAGE_NAME=ondewo-python-proto-compiler
OUTPUT_DIR=output
PROTO_DIR=protos

build:
	docker build -t ${IMAGE_NAME} .

make_output_dir:
	@if [ ! -d "${OUTPUT_DIR}" ] ; then \
		mkdir "${OUTPUT_DIR}";\
	fi


generate_protos: make_output_dir
	for f in $(find . -type f -iname "${INTERNAL_OUTPUT_DIR}/*.proto"); do \
		python -m grpc_tools.protoc \
			-I ${INTERNAL_PROTO_DIR} \
			--python_out=${INTERNAL_OUTPUT_DIR} \
			--mypy_out=${INTERNAL_OUTPUT_DIR} \
			--grpc_python_out=${INTERNAL_OUTPUT_DIR} \
			$$f; \
	done
