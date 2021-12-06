FROM python:3.9

WORKDIR /workspace/

ADD ondewo-proto-compiler/ondewo ondewo

COPY ondewo-proto-compiler/python/requirements.txt requirements.txt

RUN pip install -r requirements.txt

RUN mkdir clients/python clients/angular clients/nodejs clients/js

CMD for f in $(find . -path 'ondewo-nlu-api/ondewo/*proto'); do python -m grpc_tools.protoc -I . --python_out=clients/python --mypy_out=clients/python --grpc_python_out=clients/python $f ; done

