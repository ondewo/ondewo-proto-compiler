# ONDEWO gRPC client stubs (C#)

Generated from the ONDEWO protobuf API definitions by the
[ondewo-proto-compiler](https://github.com/ondewo/ondewo-proto-compiler) `csharp` image.

The package contains the generated message classes (`*.cs`) and the gRPC client/service stubs
(`*Grpc.cs`), one namespace folder per proto package.

```csharp
using Grpc.Net.Client;

using var channel = GrpcChannel.ForAddress("https://grpc-nlu.ondewo.com:443");
var client = new Sessions.SessionsClient(channel);
```

Ship your own `README.md` in the input volume to replace this file — it is packed into the
`.nupkg` as the package readme.
