FROM python:3.9


ARG compiler_directory
ARG api_directory



WORKDIR /workspace/
RUN mkdir /workspace/clients

ADD ${compiler_directory} /workspace/${compiler_directory}
ADD ${api_directory} /workspace/${api_directory}

RUN pip install -r /workspace/${compiler_directory}/python/requirements.txt

CMD for f in $(find . -path '/workspace/${api_directory}/ondewo/*proto'); do echo $f && python -m grpc_tools.protoc -I . \
    --python_out=/workspace/clients/python --mypy_out=/workspace/clients/python --grpc_python_out=/workspace/clients/python $f ; done