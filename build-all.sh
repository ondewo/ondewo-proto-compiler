#!/bin/sh
echo "##########################################################"
echo "Start building all ondewo-proto-compilers docker images ..."
echo "##########################################################"

cd python && bash build.sh && cd ..
cd angular && bash build.sh && cd ..
cd js && bash build.sh && cd ..
cd node && bash build.sh && cd ..
cd typescript && bash build.sh && cd ..

echo "##########################################################"
echo "✅ Building all ondewo-proto-compilers docker images."
echo "##########################################################"
