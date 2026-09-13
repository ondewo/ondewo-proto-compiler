#!/bin/sh
set -e
echo "---------------------------------------------------------------"
echo "Rust: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

docker build --no-cache -t ondewo-rust-proto-compiler:latest "$(dirname "$0")"

echo "---------------------------------------------------------------"
echo "✅ Rust: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
