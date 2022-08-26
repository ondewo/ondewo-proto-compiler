#Root path of all the protos to be compiled
RELATIVE_PROTOS_DIR=$1
if [ -z "$1" ]; then
    RELATIVE_PROTOS_DIR="protos"
fi


IMAGE_DATA_DIRECTORY=/image-data
DEFAULT_FILES_DIR=$IMAGE_DATA_DIRECTORY/default-lib-files

#Input volumes mouted at root
INPUT_VOLUME_FS=/input-volume
OUTPUT_VOLUME_FS=/output-volume

TEMP_SRC_DIRECTORY=$IMAGE_DATA_DIRECTORY/src
#Copy source-volume contents to new directory (to not modify the original files during compilation)
mkdir -p $TEMP_SRC_DIRECTORY
cp -r $INPUT_VOLUME_FS/* $TEMP_SRC_DIRECTORY

PROTOS_ROOT_PATH=$INPUT_VOLUME_FS/$RELATIVE_PROTOS_DIR

#If not specified take all protos in the protos root path (otherwise a relative directory)
#Subdir of the protos to be compiled
COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/$2
if [ -z "$2" ]; then
    COMPILE_SELECTED_PROTOS_DIR=$PROTOS_ROOT_PATH/
fi


#Clean output volume if exists
if [ ! -d $OUTPUT_VOLUME_FS ]; then
    echo "Destination volume not specified/ does not exist -> creating output in sourcevolume/lib directory"
    OUTPUT_VOLUME_FS=$INPUT_VOLUME_FS/lib
    mkdir -p $OUTPUT_VOLUME_FS
fi
#rm -r $OUTPUT_VOLUME_FS/*

# -------------- Check if all the requirements are there and exist if not
echo "Checking if all the source requirements are fulfilled ..."

if [ ! -f $TEMP_SRC_DIRECTORY/tsconfig.json ]; then
    echo "No tsconfig.json specified in source directory -> copying default file"
    cp $DEFAULT_FILES_DIR/tsconfig.json $TEMP_SRC_DIRECTORY/tsconfig.json
fi

if [ ! -f $TEMP_SRC_DIRECTORY/package.json ]; then
    echo "ERROR: A package.json file was not specified in the mounted directory this is however required - exitting"
    exit 1
fi

for protofile in $(find $COMPILE_SELECTED_PROTOS_DIR -iname "*.proto")
do
    cat $protofile | grep import | grep google >> $TEMP_SRC_DIRECTORY/proto-deps.txt
done

REMOVE_LINES=""
for import in $(cat $TEMP_SRC_DIRECTORY/proto-deps.txt | grep "\"" | cut -c 7-300 )
do
    OCCURENCES=$(cat $TEMP_SRC_DIRECTORY/proto-deps.txt | grep $import | wc -l)
    if [ $OCCURENCES -gt 1 ]; then
        for line in $(cat $TEMP_SRC_DIRECTORY/proto-deps.txt | grep -n $import | cut -d':' -f1 | tail -n +2)
        do
            REMOVE_LINES=$REMOVE_LINES";$line""d"
        done
        for line in $(cat $TEMP_SRC_DIRECTORY/proto-deps.txt | grep -n "//" | cut -d':' -f1)
        do
            REMOVE_LINES=$REMOVE_LINES";$line""d"
        done
    fi
done
REMOVE_LINES=$(echo $REMOVE_LINES | cut -c 2-600)

sed -i -e "$REMOVE_LINES" $TEMP_SRC_DIRECTORY/proto-deps.txt

REMOVE_IMPORT=$(cat $TEMP_SRC_DIRECTORY/proto-deps.txt  | cut -c 8-600 | sed 's/\"//g' | sed 's/\;//')
echo "$REMOVE_IMPORT" > $TEMP_SRC_DIRECTORY/proto-deps.txt

REMOVE_DUPLICATES=$(sort $TEMP_SRC_DIRECTORY/proto-deps.txt | uniq -u)
echo "$REMOVE_DUPLICATES" > $TEMP_SRC_DIRECTORY/proto-deps.txt

echo "Gooogle Protos Dependencies:"
cat $TEMP_SRC_DIRECTORY/proto-deps.txt


# -------------- Running compilation steps
bash ./compile-proto-2-stubs.sh $TEMP_SRC_DIRECTORY/api $PROTOS_ROOT_PATH $COMPILE_SELECTED_PROTOS_DIR $TEMP_SRC_DIRECTORY/proto-deps.txt
bash ./make-lib-entry-point.sh $TEMP_SRC_DIRECTORY .d.ts
bash ./make-lib-entry-point.sh $TEMP_SRC_DIRECTORY .js
bash ./compile-stubs-2-lib.sh $TEMP_SRC_DIRECTORY

# -------------- Copy results back to mounted directory

echo "Copying output files to mounted directory"
#mkdir -p $INPUT_VOLUME_FS/lib
cp -r $TEMP_SRC_DIRECTORY/lib/* $OUTPUT_VOLUME_FS
echo "Finished copying"

# -------------- END
echo ".proto to angular libary compilation finished successfully and ouput files are located in 'lib' directory of the mounted volume"