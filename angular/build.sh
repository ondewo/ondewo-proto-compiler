#!/bin/sh
set -e
echo "---------------------------------------------------------------"
echo "Angular: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build --no-cache -t ondewo-angular-proto-compiler:latest "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Angular: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
