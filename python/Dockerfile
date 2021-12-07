FROM python:3.8


ARG compiler_directory
ARG api_directory
ENV API_DIR ${api_directory}


WORKDIR /workspace/
COPY ${compiler_directory} /workspace/${compiler_directory}
COPY ${api_directory} /workspace/${api_directory}


RUN pip install -r /workspace/${compiler_directory}/python/requirements.txt

CMD find . -path "*${API_DIR}/ondewo/*proto" -exec python -m grpc_tools.protoc -I ${API_DIR}/googleapis -I ${API_DIR} \
 --python_out /workspace/clients/python --mypy_out /workspace/clients/python --grpc_python_out /workspace/clients/python {} +
