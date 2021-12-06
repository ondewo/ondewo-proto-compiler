FROM python:3.9
ARG client_directory
WORKDIR /workspace/

COPY ondewo-proto-compiler/python/requirements.txt requirements.txt

RUN pip install -r requirements.txt

ENDPOINT for f in $(find . -path 'ondewo-nlu-api/ondewo/*proto'); do echo $f && python -m grpc_tools.protoc -I . \
    --python_out=clients/python --mypy_out=clients/python --grpc_python_out=clients/python $f ; done \