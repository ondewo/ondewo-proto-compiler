#!/bin/sh
echo "---------------------------------------------------------------"
echo "Node.js: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build -t ondewo-nodejs-proto-compiler "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Node.js: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
