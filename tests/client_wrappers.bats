#!/usr/bin/env bats
# Unit tests for js/image-data/generate-client-wrappers.sh — the wrapper
# template must be appended per *Client class with the namespace substituted
# (portable sed extraction; BSD/macOS grep has no -P), and module.exports must
# end up as the last line again. Protos without services (no *grpc_web_pb.js
# files) must be a silent no-op.

load 'helpers/setup'

setup() {
  common_setup
  API="$SANDBOX/api"
  mkdir -p "$API"
}
teardown() { common_teardown; }

@test "wrapper appended per Client class, namespace substituted, exports moved last" {
  cat > "$API/svc_grpc_web_pb.js" <<'EOF'
proto.ondewo.nlu.AgentsClient =
    function(hostname, credentials, options) {};
module.exports = proto.ondewo.nlu;
EOF
  run bash "$REPO_ROOT/js/image-data/generate-client-wrappers.sh" "$API"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated client file"* ]]
  # template appended with Client -> AgentsClient and NAMESPACE -> proto.ondewo.nlu
  run grep -Fq "proto.ondewo.nlu.AgentsClientWrapper = function(config)" "$API/svc_grpc_web_pb.js"
  [ "$status" -eq 0 ]
  # no un-substituted placeholder remains
  run grep -Fq "NAMESPACE" "$API/svc_grpc_web_pb.js"
  [ "$status" -ne 0 ]
  # module.exports is the last line again (wrappers are defined before it)
  run tail -1 "$API/svc_grpc_web_pb.js"
  [ "$output" = "module.exports = proto.ondewo.nlu;" ]
}

@test "no *grpc_web_pb.js files (protos without services) is a silent no-op" {
  run bash "$REPO_ROOT/js/image-data/generate-client-wrappers.sh" "$API"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Updated client file"* ]]
}

@test "a stub without Client classes is left untouched" {
  printf 'var x = 1;\nmodule.exports = proto.plain;\n' > "$API/plain_grpc_web_pb.js"
  run bash "$REPO_ROOT/js/image-data/generate-client-wrappers.sh" "$API"
  [ "$status" -eq 0 ]
  run cat "$API/plain_grpc_web_pb.js"
  [[ "$output" != *"ClientWrapper"* ]]
}
