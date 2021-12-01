FROM python:3.9

WORKDIR /workspace/

ADD ondewo-proto-compiler/ondewo ondewo

COPY python/requirements.txt requirements.txt

RUN pip install -r requirements.txt


ENTRYPOINT echo "Done!"
