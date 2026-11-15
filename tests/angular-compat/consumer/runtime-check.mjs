// Runtime half of the Angular compat check (see ../run-compat.sh), run in Node on ONE Angular major:
//   node runtime-check.mjs <library_package_name> <expected_angular_version_spec>
// JIT mode: the library's partial declarations are compiled by THIS major's @angular/compiler.
import '@angular/compiler';
import { createEnvironmentInjector, importProvidersFrom, Injector, VERSION } from '@angular/core';
import { GRPC_CLIENT_FACTORY, GrpcCoreModule } from '@ngx-grpc/core';
import { GrpcDataEvent, GrpcStatusEvent } from '@ngx-grpc/common';
import { firstValueFrom, of } from 'rxjs';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { checkDeclarations } from './declaration-gate.mjs';

const [packageName, expectedVersion] = process.argv.slice(2);
const fail = (message) => {
  console.error(`FAIL: ${message}`);
  process.exit(1);
};

// 0. We are really on the major under test.
const expectedMajor = expectedVersion.replace(/^[^0-9]*/, '').split('.')[0];
if (VERSION.major !== expectedMajor) {
  fail(`@angular/core is ${VERSION.full}, expected major ${expectedMajor}`);
}

// 1. Every partial declaration links on this major (see declaration-gate.mjs for why the gate is
//    `minVersion`, not the `version` stamp of the compiler that built the library).
const require = createRequire(import.meta.url);
const packageJsonPath = require.resolve(`${packageName}/package.json`);
const bundlePath = join(dirname(packageJsonPath), JSON.parse(readFileSync(packageJsonPath, 'utf8')).module);
const declarations = checkDeclarations(readFileSync(bundlePath, 'utf8'), VERSION.full);
if (declarations.count === 0) {
  fail('no ɵɵngDeclare* partial declarations found in the library bundle');
}
if (declarations.tooNew.length > 0) {
  fail(`declarations need Angular >= ${declarations.tooNew.join(', ')}, this is ${VERSION.full}`);
}
const builtBy = declarations.builtBy.join(', ');

const lib = await import(packageName);

// 2. Every generated gRPC client is injectable and every RPC goes through GrpcHandler to the
//    transport with a serialisable request and comes back as an instance of its response class.
let rpcs = 0;
const roundTrip = (data, cls) => {
  const message = data instanceof cls ? data : new cls(data);
  cls.deserializeBinary(message.serializeBinary());
};
const transport = (path, request, metadata, requestClass, responseClass) => {
  roundTrip(request, requestClass);
  rpcs++;
  return of(new GrpcDataEvent(new responseClass()), new GrpcStatusEvent(0, 'OK', metadata));
};
const fakeClientFactory = {
  createClient: (serviceId, settings) => ({
    getSettings: () => settings,
    unary: transport,
    serverStream: transport,
  }),
};

const injector = createEnvironmentInjector(
  [importProvidersFrom(GrpcCoreModule.forRoot()), { provide: GRPC_CLIENT_FACTORY, useValue: fakeClientFactory }],
  Injector.create({ providers: [] }),
);
const clients = Object.entries(lib).filter(
  ([name, value]) => typeof value === 'function' && value.ɵprov && /Client$/.test(name),
);
if (clients.length === 0) {
  fail('no injectable *Client classes exported');
}
for (const [name, cls] of clients) {
  const client = injector.get(cls);
  if (!(client instanceof cls)) {
    fail(`${name} did not inject`);
  }
  for (const method of Object.keys(client.$raw)) {
    const response = await firstValueFrom(client[method]({}));
    if (response === undefined || typeof response.serializeBinary !== 'function') {
      fail(`${name}.${method} returned no message`);
    }
  }
}

// 3. Every generated message class constructs, serialises, deserialises and converts to an object.
const messages = Object.entries(lib).filter(
  ([, value]) => typeof value === 'function' && typeof value.id === 'string' && typeof value.deserializeBinary === 'function',
);
for (const [name, cls] of messages) {
  try {
    const message = new cls();
    cls.deserializeBinary(message.serializeBinary());
    message.toObject();
  } catch (error) {
    fail(`message ${name}: ${error}`);
  }
}

console.log(
  `OK: Angular ${VERSION.full}: ${clients.length} clients, ${rpcs} RPCs, ${messages.length} messages ` +
    `(${declarations.count} partial declarations, compiled by Angular ${builtBy})`,
);
