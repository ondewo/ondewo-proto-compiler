#!/bin/sh
set -e
#Excute the example compilation (by runnning the image with mounting this directory in the image)
FILEDIRECTORY="$(cd "$(dirname "$0")" && pwd)"

# NOTE: this example deliberately ships NO Cargo.toml, so the image falls back to its default
# crate manifest (image-data/default-lib-files/Cargo.toml, crate name "ondewo-proto-stubs").
# A real client MUST mount its own Cargo.toml next to its protos: unlike a package.json name,
# a crate name is the consumer-facing import path, so every client relying on the default
# would publish - and collide on - the same crate.
#
# Hand-written modules (a Keycloak/bearer auth surface, ...) belong under <input-volume>/src/:
# they are copied into the generated crate and declared in src/lib.rs by make-lib-entry-point.sh.

# Consume protos (and optionally Cargo.toml + src/) from the input volume and write the
# generated crate to the output volume. Entrypoint args: <relative_protos_dir> [<target_subdir>]
if [ -z "$1" ]; then
    mkdir -p "$FILEDIRECTORY/lib"
    docker run -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-rust-proto-compiler protos
else
    #Use bash inside container for debugging container and script issues
    docker run -it --entrypoint /bin/bash -v "$FILEDIRECTORY":/input-volume -v "$FILEDIRECTORY/lib":/output-volume ondewo-rust-proto-compiler
fi

# No ouput volume -> creates ouput directory "/lib" in mounted input volume
#docker run -v $FILEDIRECTORY:/input-volume ondewo-rust-proto-compiler
