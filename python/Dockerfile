FROM python:3.9

WORKDIR /workspace/

ADD protos protos

COPY python/requirements.txt requirements.txt

RUN pip install -r requirements.txt

COPY Makefile .

ENTRYPOINT make generate_protos
