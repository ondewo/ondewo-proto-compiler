FROM python:3.8 
ARG CD=CD
RUN echo $CD
WORKDIR /home/ondewo/ondewo-proto-compiler
COPY ${CD}/ondewo/ondewo-proto-compiler/python/requirements.txt .
RUN pip install -r requirements.txt

COPY Makefile .

ENTRYPOINT make generate_protos
