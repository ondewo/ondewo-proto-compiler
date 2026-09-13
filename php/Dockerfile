ARG PHP_VERSION=8.4
ARG COMPOSER_VERSION=2.8

# --------------- Composer ships as a phar; take it from the official image (pinned, no installer script)
FROM composer:${COMPOSER_VERSION} AS composer-bin

FROM php:${PHP_VERSION}-cli

# protobuf version for compiling proto files
ARG PROTOC_VERSION=32.0

# --------------- Versions baked into the shipped library manifest
# image-data/default-lib-files/composer.json carries no literal version: every version below is
# substituted into it at image-build time (see the sed further down), so these ARG lines stay the
# single source of truth and the Makefile release targets only have to rewrite this Dockerfile -
# exactly like java's pom.xml placeholders and csharp's MSBuild properties.
#
# Both runtime packages are pinned EXACTLY rather than floated with `^`: the prewarm below freezes
# the image on whatever it resolves, so a floating constraint would silently change the shipped
# protobuf/grpc runtime on every image rebuild.
# GOOGLE_PROTOBUF_PHP_VERSION must stay on the 4.x line that matches PROTOC_VERSION (protoc
# 26.x-33.x <-> the PHP 4.x runtime); the 5.x line requires php >= 8.2.0.
ARG GOOGLE_PROTOBUF_PHP_VERSION=4.33.6
ARG GRPC_PHP_VERSION=1.82.0
# Default <version> of the generated library, bumped by the release targets.
ARG ONDEWO_PROTO_COMPILER_VERSION=5.14.0

# --------------- Installing the OS toolchain
# protobuf-compiler-grpc ships a PREBUILT /usr/bin/grpc_php_plugin (Debian trixie 1.51.1-6);
# building grpc from source just for that plugin takes tens of minutes. It pulls in Debian's own
# protobuf-compiler (protoc 3.21.12 at /usr/bin/protoc), which the pinned protoc below shadows
# from /usr/local/bin. unzip is load-bearing TWICE over: once for the protoc release zip, and once
# because php:<v>-cli ships no ext-zip, so composer extracts every --prefer-dist archive through
# the unzip binary. jq drives the composer.json rewrites in make-lib-entry-point.sh. tree is only
# used interactively through the `--entrypoint /bin/bash` debug branch of example/run-compile.sh.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git jq protobuf-compiler-grpc unzip tree wget \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# --------------- Installing protoc (Protobuf compiler binary)
RUN wget --tries=3 --waitretry=5 --retry-connrefused \
      https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VERSION/protoc-$PROTOC_VERSION-linux-x86_64.zip \
      -O /tmp/protoc.zip && \
    unzip -o /tmp/protoc.zip -d /tmp/protoc/ && \
    cp /tmp/protoc/bin/protoc /usr/local/bin/protoc && \
    cp -r /tmp/protoc/include/* /usr/local/include && \
    chmod a+x /usr/local/bin/protoc && \
    rm -rf /tmp/protoc.zip /tmp/protoc/

# --------------- Fail the build loudly if Debian's protoc wins the PATH lookup, or the plugin is gone.
# NOTE: never pipe these checks into `head` - a pipeline's exit status is the LAST command's, so a
# missing binary would still exit 0. And `grpc_php_plugin --help` itself exits 1 ("Unknown option:
# --help"), because protoc plugins read a CodeGeneratorRequest on stdin rather than parsing a CLI;
# `command -v` is the only honest existence check here. Kept as two separate RUN lines so a failure
# names which half broke.
RUN protoc --version | grep -Fq "libprotoc $PROTOC_VERSION" \
 || { echo "ERROR: /usr/local/bin/protoc is not $PROTOC_VERSION" >&2; exit 1; }
RUN command -v grpc_php_plugin > /dev/null \
 || { echo "ERROR: grpc_php_plugin missing from PATH" >&2; exit 1; }

COPY --from=composer-bin /usr/bin/composer /usr/local/bin/composer

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
COPY image-data/ /image-data/

# --------------- Resolve the @NAME@ placeholders of the default library manifest
# This MUST run before the prewarm below, because the prewarm installs from this very file - a
# placeholder left in `require` would be handed to composer as a version constraint.
# `sed -i.bak ... && rm -f ....bak` rather than a bare `sed -i`, which is not portable to BSD sed
# (the repo lints for that, and this file is also read by the host test suite).
#
# The `version` placeholder is the one that would NOT fail on its own: composer treats a bogus
# `version` string as a warning, so without the assertion below the image would happily ship a
# library versioned "@ONDEWO_PROTO_COMPILER_VERSION@".
RUN sed -i.bak \
      -e "s|@ONDEWO_PROTO_COMPILER_VERSION@|$ONDEWO_PROTO_COMPILER_VERSION|" \
      -e "s|@GOOGLE_PROTOBUF_PHP_VERSION@|$GOOGLE_PROTOBUF_PHP_VERSION|" \
      -e "s|@GRPC_PHP_VERSION@|$GRPC_PHP_VERSION|" \
      /image-data/default-lib-files/composer.json \
 && rm -f /image-data/default-lib-files/composer.json.bak
RUN if grep -n "@[A-Z_][A-Z_]*@" /image-data/default-lib-files/composer.json >&2 ; then \
      echo "ERROR: unresolved placeholder left in the default library manifest - add a matching ARG and sed expression" >&2 ; \
      exit 1 ; \
    fi

# --------------- Pre-warm composer's package metadata + dist cache so the generation run needs no
# network at all: at run time compile-stubs-2-lib.sh sets COMPOSER_DISABLE_NETWORK=1 and resolves
# the library from this cache only. Pre-warming from the SAME file that is the default library
# manifest is what makes drift between "what is cached" and "what is required" impossible.
# Retry to ride out transient packagist failures (mirrors the wget --tries above).
#
# --no-autoloader is REQUIRED: the manifest declares autoload.classmap ["src/"] and the prewarm
#   directory has no src/, so autoloader generation would abort with
#   'Could not scan for classes inside "src/" which does not appear to be a file nor a folder'.
#   The autoloader that matters is generated at run time by compile-stubs-2-lib.sh anyway.
# --ignore-platform-req=ext-grpc is REQUIRED: the manifest declares ext-grpc (every generated
#   *Client.php stub extends \Grpc\BaseStub, which needs the grpc PECL extension at the CONSUMER)
#   and php:<v>-cli has no grpc extension. Compiling it in here would cost a ~10 minute C++ build
#   for a check this image never performs.
ENV COMPOSER_HOME=/image-data/composer-home
ENV COMPOSER_CACHE_DIR=/image-data/composer-cache
ENV COMPOSER_ALLOW_SUPERUSER=1
RUN mkdir -p /image-data/prewarm && \
    cp /image-data/default-lib-files/composer.json /image-data/prewarm/composer.json && \
    cd /image-data/prewarm && \
    for i in 1 2 3 4 5; do \
      composer install --no-dev --prefer-dist --no-interaction --no-progress \
        --no-autoloader --ignore-platform-req=ext-grpc && exit 0; \
      echo "composer install failed (attempt $i/5); retrying in 15s ..." >&2; \
      sleep 15; \
    done; \
    echo "composer install failed after 5 attempts" >&2; exit 1

# --------------- Entrypoint when the docker container is executed
ENTRYPOINT ["bash","compile-proto-2-php.sh"]
