// Package warmup is never shipped. It exists so that the docker build resolves and
// pre-downloads, at image build time, every module the generated stubs are compiled
// against - `go mod tidy` prunes a require whose packages nothing imports, so this file is
// the authoritative list of the runtime dependency surface of protoc-gen-go and
// protoc-gen-go-grpc output.
//
// Add an import here whenever a newly imported .proto makes the generators emit a new Go
// import (e.g. google/longrunning/operations.proto ->
// google.golang.org/genproto/googleapis/longrunning). A missing one shows up as
// "module lookup disabled by GOPROXY=off" during generation, not during the image build.
package warmup

import (
	// generated *_grpc.pb.go
	_ "google.golang.org/grpc"
	_ "google.golang.org/grpc/codes"
	_ "google.golang.org/grpc/status"

	// generated *.pb.go
	_ "google.golang.org/protobuf/proto"
	_ "google.golang.org/protobuf/reflect/protoreflect"
	_ "google.golang.org/protobuf/runtime/protoimpl"

	// google/protobuf/*.proto - the well known types, resolved from protoc's bundled include
	_ "google.golang.org/protobuf/types/known/anypb"
	_ "google.golang.org/protobuf/types/known/durationpb"
	_ "google.golang.org/protobuf/types/known/emptypb"
	_ "google.golang.org/protobuf/types/known/fieldmaskpb"
	_ "google.golang.org/protobuf/types/known/structpb"
	_ "google.golang.org/protobuf/types/known/timestamppb"
	_ "google.golang.org/protobuf/types/known/wrapperspb"

	// google/api, google/rpc, google/type - googleapis protos the ONDEWO apis import. These
	// are never generated here; the stubs import them from their canonical module instead.
	_ "google.golang.org/genproto/googleapis/api/annotations"
	_ "google.golang.org/genproto/googleapis/rpc/status"
	_ "google.golang.org/genproto/googleapis/type/latlng"
)
