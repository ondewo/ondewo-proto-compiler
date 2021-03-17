FROM python:3.8 

WORKDIR /home/ondewo/ondewo-proto-compiler

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY protos protos
COPY Makefile .

ENTRYPOINT make generate_protos