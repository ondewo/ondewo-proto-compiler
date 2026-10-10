#!/usr/bin/env bats
# The angular target omits client-streaming and bidirectional-streaming RPCs
# (angular/image-data/omit-client-streaming-methods.js).
#
# gRPC-web cannot send a request stream from a browser. protoc-gen-grpc-web (js/typescript)
# generates no method for such an RPC; protoc-gen-ng generated `foo(requestData: Observable<...>)`,
# which type-checks and can never work (@ondewo/vtsi-client-angular 9.0.0 `streamCallAudio`).
# The wrapper drops those methods from the CodeGeneratorRequest before protoc-gen-ng reads it.
#
# tests/fixtures/client-streams/streams.request.bin is the REAL CodeGeneratorRequest protoc
# produces for streams.proto (regenerate with tests/fixtures/client-streams/regenerate.sh). The
# real plugin is replaced by a mock that records the request it receives; method and message
# names are plain strings in the encoded descriptors, so their presence is checked with grep -a.

load 'helpers/setup'

setup() {
  common_setup
  WRAPPER="$REPO_ROOT/angular/image-data/omit-client-streaming-methods.js"
  REQUEST="$FIXTURES/client-streams/streams.request.bin"
  RECEIVED="$SANDBOX/received.bin"
  MOCK_PLUGIN="$SANDBOX/protoc-gen-ng"
  cat > "$MOCK_PLUGIN" <<MOCK
#!/usr/bin/env bash
cat > "$RECEIVED"
printf 'mock-plugin-stdout'
exit \${MOCK_PLUGIN_RC:-0}
MOCK
  chmod +x "$MOCK_PLUGIN"
  export PROTOC_GEN_NG_REAL="$MOCK_PLUGIN"
}
teardown() { common_teardown; }

has_bytes() { grep -aqF "$1" "$RECEIVED"; }
lacks_bytes() { ! grep -aqF "$1" "$RECEIVED"; }

@test "client streams: client-streaming and bidi methods are dropped from the request" {
  run node "$WRAPPER" < "$REQUEST"
  [ "$status" -eq 0 ]
  # the fixture really carries them, so their absence below is the wrapper's doing
  grep -aqF ClientUpload "$REQUEST"
  grep -aqF BidiConverse "$REQUEST"
  grep -aqF OnlyUpload "$REQUEST"
  lacks_bytes ClientUpload
  lacks_bytes BidiConverse
  lacks_bytes OnlyUpload
}

@test "client streams: unary and server-streaming methods are kept" {
  run node "$WRAPPER" < "$REQUEST"
  [ "$status" -eq 0 ]
  has_bytes UnaryLookup
  has_bytes ServerWatch
}

@test "client streams: services and every message type are kept, incl. those of omitted RPCs" {
  run node "$WRAPPER" < "$REQUEST"
  [ "$status" -eq 0 ]
  has_bytes Streams
  has_bytes OnlyClientStreams
  for message in LookupRequest LookupResponse UploadChunk UploadSummary ConverseIn ConverseOut; do
    has_bytes "$message"
  done
}

@test "client streams: exactly the omitted methods' bytes are removed" {
  run node "$WRAPPER" < "$REQUEST"
  [ "$status" -eq 0 ]
  # re-running over the filtered request changes nothing (no method left to drop) ...
  cp "$RECEIVED" "$SANDBOX/first.bin"
  run node "$WRAPPER" < "$SANDBOX/first.bin"
  [ "$status" -eq 0 ]
  cmp "$SANDBOX/first.bin" "$RECEIVED"
  # ... and the filtered request is strictly smaller than the original
  [ "$(wc -c < "$RECEIVED")" -lt "$(wc -c < "$REQUEST")" ]
}

@test "client streams: each omitted method is named on stderr" {
  run node "$WRAPPER" < "$REQUEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"omitted ondewo.fixture.streams.Streams.ClientUpload"* ]]
  [[ "$output" == *"omitted ondewo.fixture.streams.Streams.BidiConverse"* ]]
  [[ "$output" == *"omitted ondewo.fixture.streams.OnlyClientStreams.OnlyUpload"* ]]
  [[ "$output" != *"UnaryLookup"* ]]
  [[ "$output" != *"ServerWatch"* ]]
}

@test "client streams: the real plugin's stdout and exit status are passed through" {
  run node "$WRAPPER" < "$REQUEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mock-plugin-stdout"* ]]
  MOCK_PLUGIN_RC=3 run node "$WRAPPER" < "$REQUEST"
  [ "$status" -eq 3 ]
}

@test "client streams: a malformed request fails loudly instead of reaching the plugin" {
  # field 15, length-delimited, claims 100 bytes but carries 2
  printf '\172\144ab' > "$SANDBOX/bad.bin"
  run node "$WRAPPER" < "$SANDBOX/bad.bin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: omit-client-streaming-methods"* ]]
  [ ! -e "$RECEIVED" ]
}

@test "client streams: a missing real plugin fails loudly" {
  PROTOC_GEN_NG_REAL="$SANDBOX/does-not-exist" run node "$WRAPPER" < "$REQUEST"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot run"* ]]
}

@test "client streams: the angular stubs step runs protoc-gen-ng through the wrapper" {
  grep -q '^PROTO_GEN_NG=./omit-client-streaming-methods.js$' \
    "$REPO_ROOT/angular/image-data/compile-proto-2-stubs.sh"
  # protoc executes a plugin directly, so the wrapper must be executable as committed
  [ -x "$WRAPPER" ]
  [ "$(command -p git -C "$REPO_ROOT" ls-files -s angular/image-data/omit-client-streaming-methods.js | cut -c1-6)" = "100755" ]
}
