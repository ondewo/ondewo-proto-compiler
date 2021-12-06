FROM python:3.9
ARG api_directory
ARG compiler_directory

WORKDIR /workspace/

COPY ${compiler_directory}/python/requirements.txt requirements.txt

RUN pip install -r requirements.txt

CMD for f in $(find . -path '${api_directory}/ondewo/*proto'); do echo $f && python -m grpc_tools.protoc -I . \
    --python_out=clients/python --mypy_out=clients/python --grpc_python_out=clients/python $f ; done