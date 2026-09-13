#!/bin/bash
set -e

# -------------- Stage the generated stubs into a real, installable composer package
#
# Usage: compile-stubs-2-lib.sh <temp_src_directory>
#   <temp_src_directory>  root of the compilation: generated stubs in <dir>/generated-src, the
#                         library manifest in <dir>/composer.json; the package is staged into
#                         <dir>/lib, where the stubs become lib/src (the published layout)
#
# PHP has no compile step, so the autoloader IS the build - and this really runs composer, fully
# offline against the cache the image pre-warmed at build time.

#Root directory of the compilation -> composer.json + the generated stubs in generated-src/
#("generated-src", not "src": the copied input volume also lives under this root, and src/ is the
#conventional PHP source directory a client's own hand-written code would occupy.)
SRC_DIRECTORY=$1

if [ -z "$SRC_DIRECTORY" ]; then
    echo "usage: compile-stubs-2-lib.sh <temp_src_directory>" >&2
    exit 1
fi

if [ ! -d "$SRC_DIRECTORY/generated-src" ]; then
    echo "ERROR: no generated stubs directory '$SRC_DIRECTORY/generated-src' - the proto compilation step did not run - exiting" >&2
    exit 1
fi

if [ ! -f "$SRC_DIRECTORY/composer.json" ]; then
    echo "ERROR: no library manifest '$SRC_DIRECTORY/composer.json' - the entry-point step did not run - exiting" >&2
    exit 1
fi

# -------------- Start the php build process
echo "Starting php build process of library package ..."

#Start from an EMPTY staging directory, not just an empty lib/src. The shipped example mounts
#input=$FILEDIRECTORY and output=$FILEDIRECTORY/lib, so from the second run on the previous run's
#OUTPUT is part of the input volume that was copied into $SRC_DIRECTORY - landing right here, in
#the package staging directory. Wiping only src/ left the rest of it (a dropped dependency under
#vendor/, a stale composer.lock, any file the package no longer produces) to be picked up by the
#composer run below and copied back out as this run's output. Guarded with :? so an empty
#variable can never turn this into `rm -rf /`.
rm -rf "${SRC_DIRECTORY:?}/lib"
mkdir -p "$SRC_DIRECTORY/lib/src"
cp -r "$SRC_DIRECTORY"/generated-src/* "$SRC_DIRECTORY/lib/src" || { echo "ERROR: failed to stage the generated stubs into '$SRC_DIRECTORY/lib/src' - exiting" >&2; exit 1; }
cp "$SRC_DIRECTORY/composer.json" "$SRC_DIRECTORY/lib/composer.json" || { echo "ERROR: failed to stage the library manifest into '$SRC_DIRECTORY/lib' - exiting" >&2; exit 1; }

cd "$SRC_DIRECTORY/lib" || { echo "ERROR: failed to enter the library staging directory '$SRC_DIRECTORY/lib' - exiting" >&2; exit 1; }

#Everything below is offline: the image pre-warmed composer's metadata + dist cache at build time,
#and COMPOSER_DISABLE_NETWORK makes composer resolve from that cache ONLY - so a package that was
#not pre-warmed fails loudly here instead of silently dialling out to packagist.
export COMPOSER_DISABLE_NETWORK="${COMPOSER_DISABLE_NETWORK:-1}"

#Deliberately NOT --strict: the `version` field the release target bumps is a strict-mode warning
#that --strict turns into a failure (rc 2). This still catches a malformed/unparseable manifest.
echo "Validating the library manifest ..."
composer validate --no-check-publish --no-interaction \
    || { echo "ERROR: the library manifest '$SRC_DIRECTORY/lib/composer.json' is not valid - exiting" >&2; exit 1; }

#`update`, not `install`: the lock written at image-build time is keyed to the PREWARM manifest's
#content hash, so `install` against a client manifest reports "the lock file is not up to date".
#Under COMPOSER_DISABLE_NETWORK=1, `update` resolves from the cached packagist metadata, writes a
#correct composer.lock and installs vendor/ from the cached dist zips.
#--ignore-platform-req=ext-grpc: the manifest requires ext-grpc for the CONSUMER (every generated
#*Client.php extends \Grpc\BaseStub, which needs the grpc PECL extension), but this image has no
#grpc extension and does not need one to assemble the package.
echo "Resolving and installing the library dependencies (offline, from the image cache) ..."
composer update --no-dev --prefer-dist --no-interaction --no-progress --ignore-platform-req=ext-grpc \
    || { echo "ERROR: failed to install the library dependencies offline - a dependency outside the image's pre-warmed cache needs an image rebuild - exiting" >&2; exit 1; }

#--optimize turns the whole generated tree into an authoritative class map; it is also the step
#that surfaces duplicate class declarations.
echo "Building the optimized class map of the generated stubs ..."
composer dump-autoload --optimize --no-dev --no-interaction --ignore-platform-reqs \
    || { echo "ERROR: failed to build the optimized autoloader of the generated stubs - exiting" >&2; exit 1; }

# -------------- Verify the generated stubs actually load
#The PHP analogue of "fail the build rather than ship a broken client": calling initOnce() on every
#generated GPBMetadata class walks the whole descriptor dependency chain, so a missing transitive
#dependency (e.g. google/api/annotations.proto never generated) fails HERE instead of fatally at the
#client's first call. The heredoc terminator must stay in column 0 - `<<` accepts no indentation.
echo "Verifying the generated stubs load ..."
php <<'PHP' || { echo "ERROR: the generated stubs failed to load - exiting" >&2; exit 1; }
<?php
$classmapFile = "vendor/composer/autoload_classmap.php";
if (!is_file($classmapFile)) {
    fwrite(STDERR, "ERROR: $classmapFile was not generated\n");
    exit(1);
}
$classmap = require $classmapFile;
require "vendor/autoload.php";
$prefix = getcwd() . "/src/";
$count = 0;
foreach ($classmap as $class => $file) {
    if (strpos($file, $prefix) !== 0 || strpos($class, "GPBMetadata\\") !== 0) {
        continue;
    }
    $class::initOnce();
    $count++;
}
if ($count < 1) {
    fwrite(STDERR, "ERROR: no generated proto descriptors found in the class map\n");
    exit(1);
}
printf("Verified %d generated proto descriptor(s)\n", $count);
PHP

echo "Finished php build."
