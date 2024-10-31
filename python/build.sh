#!/bin/sh
echo "---------------------------------------------------------------"
echo "Python: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build -t ondewo-python-proto-compiler "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Python: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
