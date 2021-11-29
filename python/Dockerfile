FROM python:3.8 
ARG PWD
RUN echo ${PWD}
WORKDIR /home/ondewo/ondewo-proto-compiler
COPY "${PWD}/ondewo/ondewo-proto-compiler/requirements.txt" .
RUN pip install -r requirements.txt

COPY Makefile .

ENTRYPOINT make generate_protos
