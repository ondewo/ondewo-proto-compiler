#!/bin/sh
set -e
echo "---------------------------------------------------------------"
echo "Java: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build --no-cache -t ondewo-java-proto-compiler:latest "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Java: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
