IMAGE_NAME=ondewo-csharp-proto-compiler

build:
	docker build -t ${IMAGE_NAME} .

# PROTO_DIR   : proto root, RELATIVE to the current working directory. It is mounted inside the
#               input volume under its own basename, which is also what the entrypoint gets as
#               its <relative_protos_dir> argument.
# TARGET_DIR  : optional sub-directory of the proto root to scope the compilation to; empty
#               compiles every .proto below the root.
# OUTPUT_DIR  : where the generated library is written, RELATIVE to the current working
#               directory.
# PACKAGE_ID  : NuGet PackageId / AssemblyName / RootNamespace of the produced package.
PROTO_DIR=protos
TARGET_DIR=
OUTPUT_DIR=lib
PACKAGE_ID=Ondewo.Grpc.Client
run:
	[ -d $(OUTPUT_DIR) ] || mkdir -p $(OUTPUT_DIR)
	# Note: the positional arguments are quoted so an empty TARGET_DIR stays an empty $$2
	#	instead of collapsing and shifting PACKAGE_ID into its place. No -it: it breaks
	#	every non-interactive caller.
	docker run \
		-v ${shell pwd}/${PROTO_DIR}:/input-volume/${shell basename ${PROTO_DIR}} \
		-v ${shell pwd}/${OUTPUT_DIR}:/output-volume \
		${IMAGE_NAME} "${shell basename ${PROTO_DIR}}" "${TARGET_DIR}" "${PACKAGE_ID}"
