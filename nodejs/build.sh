#!/bin/sh
echo "---------------------------------------------------------------"
echo "Node.js: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build --no-cache -t ondewo-nodejs-proto-compiler:latest "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Node.js: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
