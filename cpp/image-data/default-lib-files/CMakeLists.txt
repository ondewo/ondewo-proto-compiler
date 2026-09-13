cmake_minimum_required(VERSION 3.22)

# ---------------------------------------------------------------------------------------
# Default build file for a generated ONDEWO gRPC C++ client library.
#
# Copied into the compilation source tree by compile-proto-2-cpp.sh when the mounted input
# volume does not ship a CMakeLists.txt of its own. Library name and version are injected by
# compile-stubs-2-lib.sh through -D, so this one generic file serves every client repo -
# do not hard-code them here.
#
# Nothing in this file may reach the network: no FetchContent, no ExternalProject, no
# file(DOWNLOAD), and no dependency manager (vcpkg / Conan / CPM) - each of those would fetch
# on the first configure, i.e. at GENERATION time. Generation must work with networking
# switched off once the image is built (`docker run --network none`). Dependency discovery
# goes exclusively through packages apt already installed into the image.
# ---------------------------------------------------------------------------------------

# Injected by compile-stubs-2-lib.sh; the defaults only matter for a manual cmake run.
set(ONDEWO_LIBRARY_NAME "ondewo_grpc_client" CACHE STRING "Name of the generated client library")
set(ONDEWO_LIBRARY_VERSION "0.0.0" CACHE STRING "Version of the generated client library")

project("${ONDEWO_LIBRARY_NAME}" VERSION "${ONDEWO_LIBRARY_VERSION}" LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# Consumers routinely link the stubs into a shared object of their own.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Debian's libprotobuf-dev ships no CMake package config, but CMake's own bundled FindProtobuf
# module locates it and defines protobuf::libprotobuf. libgrpc-dev (a dependency of
# libgrpc++-dev, and installed explicitly by the Dockerfile) DOES ship
# /usr/lib/<triple>/cmake/grpc/gRPCConfig.cmake, so find_package(gRPC CONFIG) works.
# These are preferred over pkg_check_modules because the installed <name>-config.cmake has to
# re-find the same dependencies on the CONSUMER's machine, where pkg-config and .pc files may
# not exist at all (macOS/Homebrew, vcpkg, Conan, Windows).
find_package(Protobuf REQUIRED)
find_package(gRPC CONFIG REQUIRED)

# protoc emits <name>.pb.cc and grpc_cpp_plugin emits <name>.grpc.pb.cc; both match *.pb.cc.
# GLOB at configure time is safe here because compile-stubs-2-lib.sh always configures a fresh
# build tree after generation - do not add build-directory re-use, it would miss new stubs.
file(GLOB_RECURSE ONDEWO_STUB_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/api/*.pb.cc")
if(NOT ONDEWO_STUB_SOURCES)
  message(FATAL_ERROR
    "No generated *.pb.cc sources under ${CMAKE_CURRENT_SOURCE_DIR}/api - "
    "the protoc step produced nothing to build.")
endif()
list(SORT ONDEWO_STUB_SOURCES)

add_library("${ONDEWO_LIBRARY_NAME}" STATIC ${ONDEWO_STUB_SOURCES})

# api/ is the include root the generated #include lines are relative to; the source root carries
# public-api.h beside it.
target_include_directories("${ONDEWO_LIBRARY_NAME}" PUBLIC
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/api>"
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>"
  "$<INSTALL_INTERFACE:include/${ONDEWO_LIBRARY_NAME}>")

target_link_libraries("${ONDEWO_LIBRARY_NAME}" PUBLIC gRPC::grpc++ protobuf::libprotobuf)

# The generated headers keep the proto package directory layout and include each other by that
# same root-relative path, so install the tree as-is. PATTERN "*.pb.h" catches both <name>.pb.h
# and <name>.grpc.pb.h.
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/api/"
        DESTINATION "include/${ONDEWO_LIBRARY_NAME}"
        FILES_MATCHING PATTERN "*.pb.h")

install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/public-api.h"
        DESTINATION "include/${ONDEWO_LIBRARY_NAME}")

install(TARGETS "${ONDEWO_LIBRARY_NAME}"
        EXPORT "${ONDEWO_LIBRARY_NAME}-targets"
        ARCHIVE DESTINATION lib)

install(EXPORT "${ONDEWO_LIBRARY_NAME}-targets"
        FILE "${ONDEWO_LIBRARY_NAME}-targets.cmake"
        NAMESPACE ondewo::
        DESTINATION "lib/cmake/${ONDEWO_LIBRARY_NAME}")

include(CMakePackageConfigHelpers)
configure_package_config_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/ondewo-client-config.cmake.in"
  "${CMAKE_CURRENT_BINARY_DIR}/${ONDEWO_LIBRARY_NAME}-config.cmake"
  INSTALL_DESTINATION "lib/cmake/${ONDEWO_LIBRARY_NAME}")
write_basic_package_version_file(
  "${CMAKE_CURRENT_BINARY_DIR}/${ONDEWO_LIBRARY_NAME}-config-version.cmake"
  VERSION "${ONDEWO_LIBRARY_VERSION}"
  COMPATIBILITY SameMajorVersion)
install(FILES
  "${CMAKE_CURRENT_BINARY_DIR}/${ONDEWO_LIBRARY_NAME}-config.cmake"
  "${CMAKE_CURRENT_BINARY_DIR}/${ONDEWO_LIBRARY_NAME}-config-version.cmake"
  DESTINATION "lib/cmake/${ONDEWO_LIBRARY_NAME}")
