ARG PYTHON_VERSION=3.12

FROM python:${PYTHON_VERSION}-slim-bookworm

WORKDIR /home/ondewo/ondewo-proto-compiler

RUN apt-get update && apt-get install -y --no-install-recommends make \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir --upgrade pip

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY Makefile .

ENTRYPOINT ["make", "generate_protos"]
