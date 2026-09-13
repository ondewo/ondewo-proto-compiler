#!/bin/sh
set -e
echo "---------------------------------------------------------------"
echo "PHP: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build --no-cache -t ondewo-php-proto-compiler:latest "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ PHP: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
