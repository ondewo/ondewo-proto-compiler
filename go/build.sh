#!/bin/sh
set -e
echo "---------------------------------------------------------------"
echo "Go: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build --no-cache -t ondewo-go-proto-compiler:latest "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Go: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
