#!/bin/sh
set -e
echo "---------------------------------------------------------------"
echo "Python: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build --no-cache -t ondewo-python-proto-compiler:latest "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Python: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
