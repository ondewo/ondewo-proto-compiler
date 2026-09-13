#!/bin/sh
set -e
echo "---------------------------------------------------------------"
echo "C#: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build --no-cache -t ondewo-csharp-proto-compiler:latest "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ C#: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
