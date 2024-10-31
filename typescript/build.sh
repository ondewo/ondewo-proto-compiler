#!/bin/sh
echo "---------------------------------------------------------------"
echo "Typescript: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build -t ondewo-typescript-proto-compiler "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Typescript: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
