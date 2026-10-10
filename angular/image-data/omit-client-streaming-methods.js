#!/usr/bin/env node
/**
 * protoc plugin wrapper around @ngx-grpc/protoc-gen-ng that omits every client-streaming and
 * bidirectional-streaming RPC from the generated service clients.
 *
 * Usage (as a protoc plugin):
 *   protoc --plugin=protoc-gen-ng=omit-client-streaming-methods.js --ng_out=DIR ...
 *
 * WHY
 * ---
 * gRPC-web cannot send a request stream from a browser: only unary and server-streaming calls
 * work. protoc-gen-grpc-web (the js and typescript targets) therefore never generates a method
 * for an RPC whose request is a stream. protoc-gen-ng has no such rule and no option for it: it
 * emits `foo(requestData: Observable<FooRequest>)` for such an RPC, a method that type-checks and
 * can never work (`@ondewo/vtsi-client-angular` 9.0.0 `streamCallAudio`, sip `sipStreamCallAudio`,
 * nlu `streamingDetectIntent`, ...). This wrapper makes the angular target match grpc-web.
 *
 * HOW
 * ---
 * The CodeGeneratorRequest protoc writes to stdin is filtered BEFORE protoc-gen-ng sees it: every
 * MethodDescriptorProto with `client_streaming = true` is dropped from its service, and the
 * filtered request is piped into the real plugin, whose stdout and exit status are passed through
 * unchanged. Nothing else in the request is touched, so every message type - including the
 * request and response messages of an omitted RPC - is still generated; unary and
 * server-streaming methods are generated exactly as before. Working on the request instead of on
 * the generated .ts means no pattern over generated text has to recognise a method.
 *
 * The filter walks the protobuf wire format directly, so it needs no dependency and copies every
 * byte it does not drop verbatim (unknown fields included). Only the paths below are descended:
 *
 *   CodeGeneratorRequest.proto_file (15) / source_file_descriptors (17) : FileDescriptorProto
 *     FileDescriptorProto.service (6)                                    : ServiceDescriptorProto
 *       ServiceDescriptorProto.method (2)                                : MethodDescriptorProto
 *         MethodDescriptorProto.client_streaming (5)                     : bool
 *
 * FileDescriptorProto.source_code_info still indexes methods by their original position; the
 * generator does not read it. A malformed request is a hard failure, never a silent pass-through.
 *
 * The real plugin is `node_modules/.bin/protoc-gen-ng` next to this script, or PROTOC_GEN_NG_REAL.
 */
'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const WIRE_VARINT = 0;
const WIRE_FIXED64 = 1;
const WIRE_LENGTH_DELIMITED = 2;
const WIRE_FIXED32 = 5;

function fail(message) {
  process.stderr.write(`ERROR: omit-client-streaming-methods: ${message}\n`);
  process.exit(1);
}

function readVarint(buf, pos) {
  let value = 0;
  let shift = 0;
  for (;;) {
    if (pos >= buf.length) fail('truncated varint in the CodeGeneratorRequest');
    const byte = buf[pos++];
    value += (byte & 0x7f) * 2 ** shift;
    if ((byte & 0x80) === 0) return [value, pos];
    shift += 7;
    if (shift > 63) fail('varint longer than 10 bytes in the CodeGeneratorRequest');
  }
}

function encodeVarint(value) {
  const bytes = [];
  while (value > 0x7f) {
    bytes.push((value % 0x80) | 0x80);
    value = Math.floor(value / 0x80);
  }
  bytes.push(value);
  return Buffer.from(bytes);
}

/** Split a message into its fields: { number, wireType, raw (whole field), value (varint), payload (len-delimited body) }. */
function parseFields(buf) {
  const fields = [];
  let pos = 0;
  while (pos < buf.length) {
    const start = pos;
    let tag;
    [tag, pos] = readVarint(buf, pos);
    const number = Math.floor(tag / 8);
    const wireType = tag % 8;
    let value = null;
    let payload = null;
    if (wireType === WIRE_VARINT) {
      [value, pos] = readVarint(buf, pos);
    } else if (wireType === WIRE_FIXED64) {
      pos += 8;
    } else if (wireType === WIRE_FIXED32) {
      pos += 4;
    } else if (wireType === WIRE_LENGTH_DELIMITED) {
      let length;
      [length, pos] = readVarint(buf, pos);
      payload = buf.subarray(pos, pos + length);
      pos += length;
    } else {
      fail(`unsupported wire type ${wireType} (field ${number}) in the CodeGeneratorRequest`);
    }
    if (pos > buf.length) fail(`field ${number} runs past the end of its message in the CodeGeneratorRequest`);
    fields.push({ number, wireType, raw: buf.subarray(start, pos), value, payload });
  }
  return fields;
}

function lengthDelimited(number, payload) {
  return Buffer.concat([encodeVarint(number * 8 + WIRE_LENGTH_DELIMITED), encodeVarint(payload.length), payload]);
}

function stringField(fields, number) {
  const field = fields.find((f) => f.number === number && f.wireType === WIRE_LENGTH_DELIMITED);
  return field ? field.payload.toString('utf8') : '';
}

/** Rebuild a message, replacing the length-delimited fields `rewrite` maps (null drops the field). */
function rewriteMessage(buf, rewrite) {
  return Buffer.concat(
    parseFields(buf).flatMap((field) => {
      const fn = field.wireType === WIRE_LENGTH_DELIMITED ? rewrite[field.number] : undefined;
      if (!fn) return [field.raw];
      const replaced = fn(field.payload);
      return replaced === null ? [] : [lengthDelimited(field.number, replaced)];
    })
  );
}

function isClientStreaming(methodBuf) {
  // last occurrence wins, as in any protobuf parser
  const flags = parseFields(methodBuf).filter((f) => f.number === 5 && f.wireType === WIRE_VARINT);
  return flags.length > 0 && flags[flags.length - 1].value !== 0;
}

const omitted = [];

function filterService(packageName, serviceBuf) {
  const serviceName = stringField(parseFields(serviceBuf), 1);
  return rewriteMessage(serviceBuf, {
    2: (methodBuf) => {
      if (!isClientStreaming(methodBuf)) return methodBuf;
      const methodName = stringField(parseFields(methodBuf), 1);
      omitted.push(`${packageName ? packageName + '.' : ''}${serviceName}.${methodName}`);
      return null;
    }
  });
}

function filterFile(fileBuf) {
  const packageName = stringField(parseFields(fileBuf), 2);
  return rewriteMessage(fileBuf, { 6: (serviceBuf) => filterService(packageName, serviceBuf) });
}

function filterRequest(requestBuf) {
  return rewriteMessage(requestBuf, { 15: filterFile, 17: filterFile });
}

const request = filterRequest(fs.readFileSync(0));
// source_file_descriptors repeats proto_file, so a method can be omitted twice; report it once
for (const name of [...new Set(omitted)].sort()) {
  process.stderr.write(
    `omit-client-streaming-methods: omitted ${name} (client/bidi streaming, unsupported by gRPC-web)\n`
  );
}

const realPlugin = process.env.PROTOC_GEN_NG_REAL || path.join(__dirname, 'node_modules', '.bin', 'protoc-gen-ng');
const result = spawnSync(realPlugin, [], { input: request, stdio: ['pipe', 'inherit', 'inherit'] });
if (result.error) fail(`cannot run ${realPlugin}: ${result.error.message}`);
process.exit(result.status === null ? 1 : result.status);
