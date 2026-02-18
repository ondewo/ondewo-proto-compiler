#!/bin/sh
echo "---------------------------------------------------------------"
echo "Typescript: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build --no-cache -t ondewo-typescript-proto-compiler:latest "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Typescript: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
