FROM python:3.8 

WORKDIR /opt/ondewo-proto-compiler

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY example example
COPY Makefile .

ENTRYPOINT make generate_protos