#Root directory of the compilation -> public api file + package.js
ANGULAR_WORKSPACE_DIR=$1
cd $ANGULAR_WORKSPACE_DIR

# -------------- Start the angular build process
echo "Starting angular build process of library package ..."
echo "Executing build (prod)"
npm run build
echo "Finished angular build."
