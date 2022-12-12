FROM python:3.8.16-slim-buster

WORKDIR /home/ondewo/ondewo-proto-compiler

RUN apt update && apt install -y make

COPY requirements.txt .

RUN pip install -r requirements.txt

COPY Makefile .

ENTRYPOINT make generate_protos
