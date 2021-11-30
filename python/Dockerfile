FROM python:slim-buster
RUN mkdir /workspace
COPY requirements.txt /workspace/requirements.txt
RUN pip install -r /workspace/requirements.txt

COPY Makefile .

ENTRYPOINT make generate_protos
