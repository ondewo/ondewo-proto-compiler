#!/bin/bash
set -e

# ---------------------------------------------------------------------------------------------
# ENTRYPOINT of the ondewo-csharp-proto-compiler image.
#
#   $1 <relative_protos_dir>  path of the proto root INSIDE the input volume; this is the protoc
#                             `-I` root. Defaults to "protos" (identical to nodejs/typescript).
#   $2 <target_subdir>        optional sub-directory below the proto root to restrict the
#                             compilation to; empty = every .proto below the root.
#   $3 <package_id>           optional NuGet PackageId / AssemblyName / RootNamespace of the
#                             produced package. Falls back to $OndewoPackageId and finally to
#                             "Ondewo.Grpc.Client". This is the csharp analogue of the js
#                             target's <lib_entry_name>: C# has no package.json in the input
#                             volume, so the package identity is passed in rather than read.
# ---------------------------------------------------------------------------------------------

#Root path of all the protos to be compiled
RELATIVE_PROTOS_DIR=$1
if [ -z "$1" ]; then
    RELATIVE_PROTOS_DIR="protos"
fi


#Container defaults; env-overridable so the script can run (and be tested) outside the image
IMAGE_DATA_DIRECTORY="${IMAGE_DATA_DIRECTORY:-/image-data}"
DEFAULT_FILES_DIR=$IMAGE_DATA_DIRECTORY/default-lib-files

#Input volumes mounted at root
INPUT_VOLUME_FS="${INPUT_VOLUME_FS:-/input-volume}"
OUTPUT_VOLUME_FS="${OUTPUT_VOLUME_FS:-/output-volume}"

#Compilation happens in a copy of the input volume, never in the mount itself.
#Explicitly overridable (the js target idiom) so the bats suite can drive this on the host.
TEMP_SRC_DIRECTORY="${TEMP_SRC_DIRECTORY:-$IMAGE_DATA_DIRECTORY/src}"

#Local folder feed holding the NuGet packages pre-warmed at image-build time
NUGET_OFFLINE_FEED="${NUGET_OFFLINE_FEED:-/nuget/offline-feed}"

echo "---------------------------------------------------------------"
echo "C#: Starting .proto to grpc client stubs compilation ..."
echo "---------------------------------------------------------------"

# -------------- Resolve and validate the package identity
# The .csproj template reads $(OndewoPackageId) for AssemblyName / RootNamespace / PackageId /
# DocumentationFile. Leaving it unset does NOT fail the build - AssemblyName and PackageId
# silently recover from the project file name, but the XML doc file is emitted as a nameless
# ".xml" that `dotnet pack` then drops with NU5119 - so it is resolved and exported here.
PACKAGE_ID=$3
if [ -z "$PACKAGE_ID" ]; then
    PACKAGE_ID="${OndewoPackageId:-Ondewo.Grpc.Client}"
fi
case "$PACKAGE_ID" in
    *[!A-Za-z0-9._-]*)
        echo "ERROR: invalid package id '$PACKAGE_ID' - it becomes the .csproj file name, the" >&2
        echo "       assembly name and the NuGet PackageId, so only letters, digits, '.', '_'" >&2
        echo "       and '-' are allowed (e.g. Ondewo.Nlu.Client) - exiting" >&2
        exit 1
        ;;
esac
export OndewoPackageId="$PACKAGE_ID"
#The protoc -I root, relative to the project directory; the .csproj keeps it out of the assembly
export OndewoProtosDir="$RELATIVE_PROTOS_DIR"

# -------------- Validate the pinned build properties
# The .csproj template deliberately carries no literal version - it reads these MSBuild
# properties, which the image sets from its ARG lines. An unset one does not fail the build, it
# silently produces a package with an empty TargetFramework or a stray 1.0.0 version, so it is
# caught here instead.
for REQUIRED_PROPERTY in \
    OndewoTargetFramework \
    OndewoPackageVersion \
    GoogleProtobufVersion \
    GrpcDotnetVersion \
    GoogleApiCommonProtosVersion
do
    if [ -z "${!REQUIRED_PROPERTY:-}" ]; then
        echo "ERROR: required build property '$REQUIRED_PROPERTY' is unset or empty - it is set" >&2
        echo "       by the image (see csharp/Dockerfile) and read by the generated .csproj;" >&2
        echo "       pass it with 'docker run -e $REQUIRED_PROPERTY=<value> ...' - exiting" >&2
        exit 1
    fi
done

# -------------- Copy the mounted sources into the internal compile directory
if [ ! -d "$INPUT_VOLUME_FS" ]; then
    echo "ERROR: the input volume '$INPUT_VOLUME_FS' does not exist - mount the directory that" >&2
    echo "       holds the .proto sources with '-v <dir>:/input-volume' - exiting" >&2
    exit 1
fi

#Copy source-volume contents to new directory (to not modify the original files during compilation).
#The "/." form (rather than "/*") copies dotfiles too - a client Directory.Build.props or
#.editorconfig has to reach the compile directory - and it does not turn an EMPTY input volume
#into an unexplained copy failure; that case is reported by the .proto guard further down.
mkdir -p "$TEMP_SRC_DIRECTORY"
cp -r "$INPUT_VOLUME_FS"/. "$TEMP_SRC_DIRECTORY" || { echo "ERROR: failed to copy the input volume '$INPUT_VOLUME_FS' to '$TEMP_SRC_DIRECTORY'" >&2; exit 1; }

PROTOS_ROOT_PATH=$INPUT_VOLUME_FS/$RELATIVE_PROTOS_DIR

#If not specified take all protos in the protos root path (otherwise a relative directory)
#Subdir of the protos to be compiled
COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/$2
if [ -z "$2" ]; then
    COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/
fi

#Clean output volume if exists
if [ ! -d "$OUTPUT_VOLUME_FS" ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUT_VOLUME_FS=$INPUT_VOLUME_FS/lib
    mkdir -p "$OUTPUT_VOLUME_FS"
fi
#Clean previously generated output so renamed/deleted protos are not shipped as stale stubs.
#Only the three directories this target owns are removed - never a bare "bin"/"obj", which in a
#C# client repo mounted as the output volume would be that repository's own build output.
if [ -n "$OUTPUT_VOLUME_FS" ] && [ -d "$OUTPUT_VOLUME_FS" ]; then
    rm -rf "${OUTPUT_VOLUME_FS:?}/api" "${OUTPUT_VOLUME_FS:?}/artifacts" "${OUTPUT_VOLUME_FS:?}/nupkg"
fi

# -------------- Check if all the requirements are there and exist if not
echo "Checking if all the source requirements are fulfilled ..."

CSPROJ_FILE=$TEMP_SRC_DIRECTORY/$PACKAGE_ID.csproj
if [ ! -f "$CSPROJ_FILE" ]; then
    echo "No $PACKAGE_ID.csproj specified in source directory -> copying default file"
    cp "$DEFAULT_FILES_DIR/stubs.csproj" "$CSPROJ_FILE" || { echo "ERROR: failed to copy the default project file from '$DEFAULT_FILES_DIR/stubs.csproj'" >&2; exit 1; }
else
    echo "WARNING: using the client-supplied $PACKAGE_ID.csproj from the input volume."
    echo "         The image restores from a closed, pre-warmed offline NuGet feed, so any"
    echo "         PackageReference outside that feed fails the restore with NU1101 rather"
    echo "         than silently reaching out to nuget.org."
fi

#Packed into the .nupkg as the package readme; absence is tolerated by the project template
if [ ! -f "$TEMP_SRC_DIRECTORY/README.md" ]; then
    echo "No README.md specified in source directory -> copying default file"
    cp "$DEFAULT_FILES_DIR/README.md" "$TEMP_SRC_DIRECTORY/README.md" || { echo "ERROR: failed to copy the default README.md from '$DEFAULT_FILES_DIR/README.md'" >&2; exit 1; }
fi

#Render the offline nuget.config next to the project. Always rendered, never taken from the
#input volume: a client-supplied one would name sources this container cannot reach.
echo "Rendering nuget.config pointing at the offline feed '$NUGET_OFFLINE_FEED'"
sed "s|@NUGET_OFFLINE_FEED@|$NUGET_OFFLINE_FEED|g" "$DEFAULT_FILES_DIR/nuget.config" \
    > "$TEMP_SRC_DIRECTORY/nuget.config" || { echo "ERROR: failed to render '$TEMP_SRC_DIRECTORY/nuget.config' from '$DEFAULT_FILES_DIR/nuget.config'" >&2; exit 1; }

# -------------- Running compilation steps
bash ./compile-proto-2-stubs.sh "$TEMP_SRC_DIRECTORY/api" "$PROTOS_ROOT_PATH" "$COMPILE_SELECTED_PROTOS_DIR" || { echo "ERROR: compile-proto-2-stubs.sh failed" >&2; exit 1; }
bash ./compile-stubs-2-lib.sh "$TEMP_SRC_DIRECTORY" "$PACKAGE_ID" || { echo "ERROR: compile-stubs-2-lib.sh failed" >&2; exit 1; }

# -------------- Copy results back to mounted directory

echo "Copying output files to mounted directory"
cp -r "$TEMP_SRC_DIRECTORY"/lib/* "$OUTPUT_VOLUME_FS" || { echo "ERROR: failed to copy the library from '$TEMP_SRC_DIRECTORY/lib' to the output volume '$OUTPUT_VOLUME_FS'" >&2; exit 1; }
echo "Finished copying"

# -------------- END
echo "---------------------------------------------------------------"
echo "✅ C#: Done .proto to grpc client stubs compilation"
echo "---------------------------------------------------------------"
echo ".proto to csharp library compilation finished successfully and output files are located in the mounted output volume"
