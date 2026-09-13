ARG DOTNET_SDK_VERSION=10.0

FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_VERSION}

# protobuf version for compiling proto files
ARG PROTOC_VERSION=32.0

# --------------- Toolchain / package versions that reach MSBuild as properties
# The generated project file (image-data/default-lib-files/stubs.csproj) carries no literal
# version: every version below is handed to MSBuild as an environment property, so these ARG
# lines stay the single source of truth and the Makefile release targets only have to rewrite
# this Dockerfile.
ARG GRPC_TOOLS_VERSION=2.83.0
ARG GOOGLE_PROTOBUF_VERSION=3.32.0
ARG GRPC_DOTNET_VERSION=2.83.0
ARG GOOGLE_API_COMMONPROTOS_VERSION=2.17.0
ARG DOTNET_TARGET_FRAMEWORK=netstandard2.0
ARG ONDEWO_PACKAGE_ID=Ondewo.Grpc.Client
ARG ONDEWO_PROTO_COMPILER_VERSION=5.15.0

# MSBuild reads environment variables as properties. OndewoPackageId is what drives
# AssemblyName / RootNamespace / PackageId / DocumentationFile - leaving it unset makes the
# build emit a nameless ".xml" doc file that `dotnet pack` then refuses to include (NU5119).
ENV OndewoTargetFramework=${DOTNET_TARGET_FRAMEWORK} \
    OndewoPackageId=${ONDEWO_PACKAGE_ID} \
    OndewoPackageVersion=${ONDEWO_PROTO_COMPILER_VERSION} \
    GoogleProtobufVersion=${GOOGLE_PROTOBUF_VERSION} \
    GrpcDotnetVersion=${GRPC_DOTNET_VERSION} \
    GoogleApiCommonProtosVersion=${GOOGLE_API_COMMONPROTOS_VERSION}

# --------------- dotnet CLI hygiene for containers
# NUGET_PACKAGES / NUGET_OFFLINE_FEED are the pre-warmed caches (see the warm-up RUN below);
# DOTNET_CLI_HOME keeps the CLI off an unwritable $HOME; MSBUILDDISABLENODEREUSE stops MSBuild
# from leaving worker nodes behind in the container.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_CLI_HOME=/tmp \
    MSBUILDDISABLENODEREUSE=1 \
    NUGET_PACKAGES=/nuget/packages \
    NUGET_OFFLINE_FEED=/nuget/offline-feed

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates unzip tree wget \
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

# --------------- Installing the C# gRPC codegen plugin
# There is no standalone grpc_csharp_plugin release on GitHub; the binary ships inside the
# Grpc.Tools NuGet package at tools/linux_x64/grpc_csharp_plugin. A .nupkg is a plain zip, so
# it is fetched with wget and unzipped - no `dotnet tool install` and no NuGet source needed.
# NOTE: that zip entry records no unix mode (external_attr=0), so unzip extracts it as mode 000.
# An explicit `chmod 0755` is required - `chmod a+x` would leave it unreadable.
RUN wget --tries=3 --waitretry=5 --retry-connrefused \
      https://api.nuget.org/v3-flatcontainer/grpc.tools/${GRPC_TOOLS_VERSION}/grpc.tools.${GRPC_TOOLS_VERSION}.nupkg \
      -O /tmp/grpc.tools.nupkg && \
    unzip -o -j /tmp/grpc.tools.nupkg "tools/linux_x64/grpc_csharp_plugin" -d /usr/local/bin && \
    chmod 0755 /usr/local/bin/grpc_csharp_plugin && \
    rm -f /tmp/grpc.tools.nupkg

# --------------- Copy all files from "image-data" directory to docker container
WORKDIR /image-data
COPY image-data/ /image-data/

# --------------- Pre-warm the NuGet graph so generation needs no network
# The default project template IS the warm-up project, so the package graph restored here is
# the graph a generation run resolves. Every .nupkg NuGet left in the global packages folder is
# harvested into a local folder feed (a superset of the resolved graph - resolution downloads
# several candidate versions of System.Memory / System.Buffers / ...); at run time
# `dotnet restore --source $NUGET_OFFLINE_FEED` reads only that feed.
# Retry to ride out transient nuget.org failures (mirrors the wget --tries above); the sentinel
# makes 5 failed attempts abort here instead of falling through to `dotnet build --no-restore`,
# which would die with an unrelated NETSDK1004 "Assets file project.assets.json not found".
RUN mkdir -p /nuget/warmup "$NUGET_OFFLINE_FEED" && \
    cp /image-data/default-lib-files/stubs.csproj /nuget/warmup/warmup.csproj && \
    cp /image-data/default-lib-files/README.md /nuget/warmup/README.md && \
    printf 'namespace Ondewo.Warmup { internal static class Warmup { } }\n' > /nuget/warmup/Warmup.cs && \
    ok=0; \
    for i in 1 2 3 4 5; do \
      if dotnet restore /nuget/warmup/warmup.csproj \
           -p:OndewoPackageId=Ondewo.Warmup -p:OndewoPackageVersion=0.0.0; then ok=1; break; fi; \
      echo "dotnet restore failed (attempt $i/5); retrying in 15s ..." >&2; \
      sleep 15; \
    done; \
    [ "$ok" -eq 1 ] || { echo "dotnet restore failed after 5 attempts" >&2; exit 1; } && \
    dotnet build /nuget/warmup/warmup.csproj -c Release --no-restore \
      -p:OndewoPackageId=Ondewo.Warmup -p:OndewoPackageVersion=0.0.0 && \
    find "$NUGET_PACKAGES" -name "*.nupkg" -exec cp {} "$NUGET_OFFLINE_FEED"/ ';' && \
    rm -rf /nuget/warmup && \
    chmod -R a+rwX /nuget

# --------------- Entrypoint when the docker container is executed
ENTRYPOINT ["bash","compile-proto-2-csharp.sh"]
