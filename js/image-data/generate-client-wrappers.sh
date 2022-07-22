#!/bin/bash

SOURCE_DIR="$1"
#TARGET_DIR="$2"

echo "Generate and append client wrappers, search in dir: $SOURCE_DIR"

TEMPLATE_CONTENTS=$(cat /image-data/default-lib-files/client-wrapper-es5-template.js)
JAVASCRIPT_FILES=$(find "$SOURCE_DIR" -iname "*grpc_web_pb.js")
NAME_SPACE="proto.ondewo.survey"

while IFS= read -r JAVASCRIPT_FILE; do

    JAVASCRIPT_CONTENT=$(cat "$JAVASCRIPT_FILE")
    NAME_SPACE_LINE=$(echo "$JAVASCRIPT_CONTENT" | grep -E "module\.exports[ ]+=.+")
    NAME_SPACE=$(echo "$NAME_SPACE_LINE" | grep -o -P "(?<=\ )[a-zA-Z0-9_\-\.]+(?=;)")

    CLIENT_CLASS_LINES=$(echo "$JAVASCRIPT_CONTENT" | grep -E "[\.a-zA-Z0-9_\-]+Client[ ]+=")
    CLIENT_NAMES=$(echo "$CLIENT_CLASS_LINES" | grep -o -P "(?<=\.)[a-zA-Z0-9_\-]+(?=\ )")

    if [ -n "$CLIENT_NAMES" ]; then
        echo "$CLIENT_NAMES" | \
        xargs -I % bash -c \
        "echo \"$TEMPLATE_CONTENTS\" | \
        sed \"s/Client/%/\" | \
        sed \"s/NAMESPACE/$NAME_SPACE/\" \
        >> \"$JAVASCRIPT_FILE\""

        sed -i "s/module.exports = $NAME_SPACE;//" "$JAVASCRIPT_FILE"

        echo "module.exports = $NAME_SPACE;" >> "$JAVASCRIPT_FILE"

        echo "Updated client file: $JAVASCRIPT_FILE"
    fi

done <<< $JAVASCRIPT_FILES