#Root directory of the compilation -> public api file + package.js
ANUGULAR_PROJECT_DIR=$1
SRC_DIRECTORY=$2

# -------------- Start the angular build process
echo "Starting angular build process of library package ..."

echo "Installing src package dependecies"
cd $SRC_DIRECTORY
npm install

echo "Installing angular compilation dependencies"
cd $ANUGULAR_PROJECT_DIR
#npm install

echo "Executing ng-packagr build script'"
#ng build --prod
npm run build

#echo "Packagin and compiling angular application 'ng-packagr -p'"
#cd $SRC_DIRECTORY
#ng-packagr -p

echo "Finished angular build."