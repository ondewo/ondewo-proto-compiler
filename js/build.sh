#!/bin/sh
echo "---------------------------------------------------------------"
echo "Javascript: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build --no-cache -t ondewo-js-proto-compiler:latest "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Javascript: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
