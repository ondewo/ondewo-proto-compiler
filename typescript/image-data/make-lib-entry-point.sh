# -------------- Create pulbic-api.js from the commonjs output of the proto compilation step
# to pass a single file to webpack as an entry point

#Root directory of the compilation ( -> public api file in this directory + proto commonjs stubs are in this/api )
TEMP_SRC_DIRECTORY=$1

FILE_EXTENSION=$2
if [ -z "$2" ]; then
    FILE_EXTENSION=".d.ts"
fi

#Location of the directory where the target api file will be put
#OUT_DIRECTORY=$2
DEFAULT_FILES_DIR=default-lib-files

#Can also be specified in provided directory -> no auto generation
PUBLIC_API_FILE=$TEMP_SRC_DIRECTORY/public-api$FILE_EXTENSION

if [ ! -f $PUBLIC_API_FILE ]; then
    echo "No public-api$FILE_EXTENSION specified in source directory -> copying default file"
    cp $DEFAULT_FILES_DIR/public-api$FILE_EXTENSION $PUBLIC_API_FILE

    # Trying to auto generate public-api file
    cd $TEMP_SRC_DIRECTORY

    #ES6 Style exports
    export PREFIX="export * from '"
    export POSTFIX="';"

    #find api -iname "*.ts" -printf "$PREFIX%p$POSTFIX\n" >> $PUBLIC_API_FILE
    find api -iname "*$FILE_EXTENSION" -exec bash -c 'printf "$PREFIX./%s$POSTFIX\n" "${@%.*}"' _ {} + >> $PUBLIC_API_FILE
fi