ARG PYTHON_VERSION=3.9.16

FROM python:${PYTHON_VERSION}-buster

WORKDIR /home/ondewo/ondewo-proto-compiler

RUN apt update && apt install -y make

RUN pip install --upgrade pip

COPY requirements.txt .

RUN pip install -r requirements.txt

COPY Makefile .

ENTRYPOINT make generate_protos
