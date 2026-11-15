// Behavioural assertions on the compiled fixture client (fixture-client/protos/ondewo/compat/compat.proto),
// run by consumer/check.sh on EVERY Angular major under test: node extra-check.mjs <package_name>.
// They pin the generated-code semantics this repo deliberately patches (5.14.0 / 5.15.7), so a
// toolchain upgrade that silently changes them fails here instead of in a client application.
import '@angular/compiler';
import { createEnvironmentInjector, importProvidersFrom, Injector, VERSION } from '@angular/core';
import { GRPC_CLIENT_FACTORY, GrpcCoreModule } from '@ngx-grpc/core';
import { GrpcDataEvent, GrpcStatusEvent } from '@ngx-grpc/common';
import { lastValueFrom, of, toArray } from 'rxjs';
import assert from 'node:assert/strict';

const { CompatClient, Item, Mode } = await import(process.argv[2]);

// proto3 explicit presence: an explicitly set false / 0 is sent and read back, an unset field stays unset.
const roundTripped = Item.deserializeBinary(new Item({ enabled: false, count: 0 }).serializeBinary());
assert.equal(roundTripped.enabled, false, 'optional bool false must survive the wire');
assert.equal(roundTripped.count, 0, 'optional int32 0 must survive the wire');
const unset = Item.deserializeBinary(new Item().serializeBinary());
assert.equal(unset.enabled, undefined, 'an unset optional bool must stay unset');

// enums, maps, oneofs, nested repeated messages and well-known types round-trip.
const full = new Item({ name: 'x', mode: Mode.MODE_FULL, labels: { a: 'b' }, url: 'u', parts: [{ values: ['v'] }] });
const back = Item.deserializeBinary(full.serializeBinary()).toObject();
assert.equal(back.mode, Mode.MODE_FULL);
assert.deepEqual(back.labels, { a: 'b' });
assert.equal(back.url, 'u');
assert.deepEqual(back.parts[0].values, ['v']);

// client-streaming RPCs are not generated (gRPC-web cannot send a request stream), the rest are.
const paths = [];
const transport = (path, request, metadata, requestClass, responseClass) => {
  paths.push(path);
  return of(new GrpcDataEvent(new responseClass({ name: 'a' })), new GrpcDataEvent(new responseClass({ name: 'b' })),
    new GrpcStatusEvent(0, 'OK', metadata));
};
const injector = createEnvironmentInjector(
  [importProvidersFrom(GrpcCoreModule.forRoot()),
    { provide: GRPC_CLIENT_FACTORY, useValue: { createClient: () => ({ unary: transport, serverStream: transport }) } }],
  Injector.create({ providers: [] }),
);
const client = injector.get(CompatClient);
assert.deepEqual(Object.keys(client.$raw).sort(), ['getItem', 'ping', 'watchItems']);
assert.equal(client.uploadItems, undefined, 'client-streaming UploadItems must be omitted');
const streamed = await lastValueFrom(client.watchItems(new Item()).pipe(toArray()));
assert.deepEqual(streamed.map((m) => m.name), ['a', 'b'], 'server streaming delivers every message');
assert.deepEqual(paths, ['/ondewo.compat.Compat/WatchItems']);

console.log(`OK: fixture semantics hold on Angular ${VERSION.full}`);
