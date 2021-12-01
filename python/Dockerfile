FROM python:3.9

WORKDIR /workspace/

ADD ondewo-proto-compiler/ondewo ondewo

COPY ondewo-proto-compiler/python/requirements.txt requirements.txt

RUN pip install -r requirements.txt

CMD for f in $(find . -path '*proto'); do python -m grpc_tools.protoc -I . --python_out=output --mypy_out=output --grpc_python_out=output $f ; done

