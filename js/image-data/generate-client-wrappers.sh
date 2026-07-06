#!/bin/bash
set -e

SOURCE_DIR="$1"
#TARGET_DIR="$2"

echo "Generate and append client wrappers, search in dir: $SOURCE_DIR"

# Resolve the template relative to this script so it also works outside the
# container image (where image-data is not located at /image-data)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_CONTENTS=$(cat "$SCRIPT_DIR/default-lib-files/client-wrapper-es5-template.js")
JAVASCRIPT_FILES=$(find "$SOURCE_DIR" -iname "*grpc_web_pb.js")

while IFS= read -r JAVASCRIPT_FILE; do

    # find legitimately returns no files for protos without services
    [ -n "$JAVASCRIPT_FILE" ] || continue

    JAVASCRIPT_CONTENT=$(cat "$JAVASCRIPT_FILE")
    NAME_SPACE_LINE=$(echo "$JAVASCRIPT_CONTENT" | grep -E "module\.exports[ ]+=.+" || true)
    # extract "proto.x.y" from "module.exports = proto.x.y;" (portable sed, no grep -P on BSD/macOS)
    NAME_SPACE=$(echo "$NAME_SPACE_LINE" | sed -n 's|.*[[:space:]]\([a-zA-Z0-9_.-]*\);.*|\1|p')

    CLIENT_CLASS_LINES=$(echo "$JAVASCRIPT_CONTENT" | grep -E "[\.a-zA-Z0-9_\-]+Client[ ]+=" || true)
    # extract "FooClient" from "proto.x.y.FooClient =" (last dot-segment before a space)
    CLIENT_NAMES=$(echo "$CLIENT_CLASS_LINES" | sed -n 's|.*\.\([a-zA-Z0-9_-]*\)[[:space:]].*|\1|p')

    if [ -n "$CLIENT_NAMES" ] && [ -n "$NAME_SPACE" ]; then
        # Plain shell loop instead of `xargs -I % bash -c "<template>"`: BSD/macOS
        # xargs caps an -I-constructed argument containing the replstr at 255 bytes,
        # so cramming the ~900-byte template into one bash -c arg fails there. The
        # loop keeps the original substitution order (Client first, then NAMESPACE).
        echo "$CLIENT_NAMES" | while IFS= read -r CLIENT_NAME; do
            [ -n "$CLIENT_NAME" ] || continue
            echo "$TEMPLATE_CONTENTS" \
                | sed "s/Client/$CLIENT_NAME/" \
                | sed "s/NAMESPACE/$NAME_SPACE/" \
                >> "$JAVASCRIPT_FILE"
        done

        # -i.bak (not bare -i) keeps this working with both GNU and BSD/macOS sed
        sed -i.bak "s/module.exports = $NAME_SPACE;//" "$JAVASCRIPT_FILE"
        rm -f "$JAVASCRIPT_FILE.bak"

        echo "module.exports = $NAME_SPACE;" >> "$JAVASCRIPT_FILE"

        echo "Updated client file: $JAVASCRIPT_FILE"
    fi

done <<< "$JAVASCRIPT_FILES"
