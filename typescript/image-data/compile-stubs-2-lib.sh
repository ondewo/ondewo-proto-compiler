#Root directory of the compilation -> public api file + package.js
SRC_DIRECTORY=$1

# -------------- Start the angular build process
echo "Starting typescript build process of library package ..."

#echo "Installing src package dependecies"
#cd $SRC_DIRECTORY
#npm install

#echo "Executing typescript build'"
#tsc
#echo "Copying generated stubs lib to output"
mkdir -p $SRC_DIRECTORY/lib
mkdir -p $SRC_DIRECTORY/lib/api
cp -r $SRC_DIRECTORY/api/* $SRC_DIRECTORY/lib/api
cp $SRC_DIRECTORY/package.json $SRC_DIRECTORY/lib/package.json

#Copy all public api files
cd $SRC_DIRECTORY
PUB_API=$(ls | grep "public-api")
echo "$PUB_API" | xargs -I {} cp {} $SRC_DIRECTORY/lib

cd $SRC_DIRECTORY/lib
npm install


echo "Finished web build."