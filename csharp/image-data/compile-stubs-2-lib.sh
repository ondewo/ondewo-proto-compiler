#!/bin/bash
set -e

# ---------------------------------------------------------------------------------------------
# C# stubs -> distributable library package.
#
#   $1 <src_directory>  the internal compile directory (the copy of the input volume). obj/ and
#                       bin/ are written HERE, never into the mount.
#   $2 <package_id>     NuGet PackageId; also the name of the project file inside $1.
#
# All three dotnet calls are offline: restore is pinned to the folder feed pre-warmed at
# image-build time, build and pack run --no-restore so they cannot reach a source at all. A
# PackageReference outside the warmed graph therefore fails loudly with NU1101 instead of
# silently going to nuget.org.
#
# The build result is assembled into $1/lib, which the orchestrator copies to the output volume:
#
#   lib/api/              the generated stubs, nested by C# namespace
#   lib/<PackageId>.csproj  so a client repo can rebuild the package itself
#   lib/artifacts/<tfm>/  compiled assembly + symbols + XML docs
#   lib/nupkg/            the distributable .nupkg (+ .snupkg)
#
# The compiled output is deliberately NOT published as "bin/": a client mounts its repository
# ROOT as the output volume, where bin/ and obj/ are that repository's own build output, and the
# orchestrator's cleanup step must never delete those. The README.md is likewise not copied out -
# it is already inside the .nupkg via <PackageReadmeFile>, and copying it would overwrite the
# client repository's own top-level README.md on every run.
# ---------------------------------------------------------------------------------------------

#Root directory of the compilation -> the project file + the generated api/ stubs
SRC_DIRECTORY=$1
PACKAGE_ID=$2

#Local folder feed holding the NuGet packages pre-warmed at image-build time
NUGET_OFFLINE_FEED="${NUGET_OFFLINE_FEED:-/nuget/offline-feed}"

if [ -z "$SRC_DIRECTORY" ] || [ -z "$PACKAGE_ID" ]; then
    echo "ERROR: usage: compile-stubs-2-lib.sh <src_directory> <package_id> - exiting" >&2
    exit 1
fi
if [ ! -d "$SRC_DIRECTORY" ]; then
    echo "ERROR: the compile directory '$SRC_DIRECTORY' does not exist - exiting" >&2
    exit 1
fi

LIB_DIR=$SRC_DIRECTORY/lib
CSPROJ=$SRC_DIRECTORY/$PACKAGE_ID.csproj

if [ ! -f "$CSPROJ" ]; then
    echo "ERROR: no project file '$CSPROJ' - it is rendered by compile-proto-2-csharp.sh from" >&2
    echo "       default-lib-files/stubs.csproj unless the input volume ships one - exiting" >&2
    exit 1
fi
if [ ! -d "$SRC_DIRECTORY/api" ]; then
    echo "ERROR: no generated stubs directory '$SRC_DIRECTORY/api' - compile-proto-2-stubs.sh" >&2
    echo "       has to run before the package is built - exiting" >&2
    exit 1
fi

# -------------- Start the dotnet build process
echo "Starting csharp build process of library package ..."
cd "$SRC_DIRECTORY" || exit 1

#Start from an empty assembly directory BEFORE anything compiles: when the output volume is
#nested in the input volume (the example) or falls back to <input>/lib, a previous run's lib/ is
#part of the copied-in sources, and the SDK's default Compile glob - which excludes only bin/ and
#obj/ - would feed every generated type to the compiler a second time (CS0101). Removing it here
#also keeps renamed/deleted stubs from being shipped again.
rm -rf "${LIB_DIR:?}"
mkdir -p "$LIB_DIR"

echo "Restoring '$PACKAGE_ID' from the offline NuGet feed '$NUGET_OFFLINE_FEED' ..."
dotnet restore "$CSPROJ" --source "$NUGET_OFFLINE_FEED" || { echo "ERROR: dotnet restore of '$CSPROJ' failed - every PackageReference must be present in the pre-warmed offline feed '$NUGET_OFFLINE_FEED'" >&2; exit 1; }

echo "Building '$PACKAGE_ID' ..."
dotnet build "$CSPROJ" -c Release --no-restore || { echo "ERROR: dotnet build of '$CSPROJ' failed" >&2; exit 1; }

echo "Packing '$PACKAGE_ID' ..."
dotnet pack "$CSPROJ" -c Release --no-restore --no-build -o "$LIB_DIR/nupkg" || { echo "ERROR: dotnet pack of '$CSPROJ' failed" >&2; exit 1; }

# -------------- Assemble what gets copied to the output volume
if [ ! -d "$SRC_DIRECTORY/bin/Release" ]; then
    echo "ERROR: dotnet build produced no '$SRC_DIRECTORY/bin/Release' output directory - exiting" >&2
    exit 1
fi

mkdir -p "$LIB_DIR/api" "$LIB_DIR/artifacts"
cp -r "$SRC_DIRECTORY/api/." "$LIB_DIR/api" || { echo "ERROR: failed to collect the generated stubs from '$SRC_DIRECTORY/api'" >&2; exit 1; }
#Copies the CONTENTS of bin/Release, so the per-target-framework sub-directory is kept and a
#multi-targeting client project stays representable: artifacts/<tfm>/<PackageId>.dll
cp -r "$SRC_DIRECTORY/bin/Release/." "$LIB_DIR/artifacts" || { echo "ERROR: failed to collect the build output from '$SRC_DIRECTORY/bin/Release'" >&2; exit 1; }
cp "$CSPROJ" "$LIB_DIR/" || { echo "ERROR: failed to collect the project file '$CSPROJ'" >&2; exit 1; }
#nuget.config is deliberately NOT collected: its feed path is image-internal and would break a
#client rebuilding the package on the host.

echo "Finished csharp build."
