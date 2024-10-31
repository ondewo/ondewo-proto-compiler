#!/bin/sh
echo "---------------------------------------------------------------"
echo "Javascript: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build -t ondewo-js-proto-compiler "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Javascript: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
