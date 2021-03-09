IMAGE_NAME=ondewo-python-proto-compiler
PROTOS_DIR=protos
OUTPUT_FOLDER=output


build:
	docker build -t ${IMAGE_NAME} .

run:
	docker run -v ${shell pwd}/output:/opt/ondewo-proto-compiler/output ${IMAGE_NAME}

generate_protos:
	for f in $$(find ${PROTOS_DIR} -name '*.proto'); do \
		python -m grpc_tools.protoc -I ${PROTOS_DIR} --python_out=${OUTPUT_FOLDER} --mypy_out=${OUTPUT_FOLDER} --grpc_python_out=${OUTPUT_FOLDER} $$f; \
	done
