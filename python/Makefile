IMAGE_NAME=ondewo-python-proto-compiler

build:
	docker build -t ${IMAGE_NAME} .

run_example:
	docker run -v ${shell pwd}:/opt/ondewo-proto-compiler -it -e PROTOS_DIR=example/protos -e APIS_DIR=example -e OUTPUT_FOLDER=. ${IMAGE_NAME}

generate_protos:
	for f in $$(find ${PROTOS_DIR} -name '*.proto'); do \
		python -m grpc_tools.protoc -I ${APIS_DIR} --python_out=${OUTPUT_FOLDER} --mypy_out=${OUTPUT_FOLDER} --grpc_python_out=${OUTPUT_FOLDER} $$f; \
	done
