/* tslint:disable */
/* eslint-disable */
// @ts-nocheck
//
// THIS IS A GENERATED FILE
// DO NOT MODIFY IT! YOUR CHANGES WILL BE LOST
import {
  GrpcMessage,
  RecursivePartial,
  ToProtobufJSONOptions
} from '@ngx-grpc/common';
import { BinaryReader, BinaryWriter, ByteSource } from 'google-protobuf';
export enum View {
  MINIMUM = 0,
  FULL = 1
}
/**
 * Message implementation for fixture.presence.Nested
 */
export class Nested implements GrpcMessage {
  static id = 'fixture.presence.Nested';

  /**
   * Deserialize binary data to message
   * @param instance message instance
   */
  static deserializeBinary(bytes: ByteSource) {
    const instance = new Nested();
    Nested.deserializeBinaryFromReader(instance, new BinaryReader(bytes));
    return instance;
  }

  /**
   * Check all the properties and set default protobuf values if necessary
   * @param _instance message instance
   */
  static refineValues(_instance: Nested) {
    _instance.nestedFlag = _instance.nestedFlag || false;
  }

  /**
   * Deserializes / reads binary message into message instance using provided binary reader
   * @param _instance message instance
   * @param _reader binary reader instance
   */
  static deserializeBinaryFromReader(_instance: Nested, _reader: BinaryReader) {
    while (_reader.nextField()) {
      if (_reader.isEndGroup()) break;

      switch (_reader.getFieldNumber()) {
        case 1:
          _instance.nestedFlag = _reader.readBool();
          break;
        default:
          _reader.skipField();
      }
    }

    Nested.refineValues(_instance);
  }

  /**
   * Serializes a message to binary format using provided binary reader
   * @param _instance message instance
   * @param _writer binary writer instance
   */
  static serializeBinaryToWriter(_instance: Nested, _writer: BinaryWriter) {
    if (_instance.nestedFlag) {
      _writer.writeBool(1, _instance.nestedFlag);
    }
  }

  private _nestedFlag: boolean;

  /**
   * Message constructor. Initializes the properties and applies default Protobuf values if necessary
   * @param _value initial values object or instance of Nested to deeply clone from
   */
  constructor(_value?: RecursivePartial<Nested.AsObject>) {
    _value = _value || {};
    this.nestedFlag = _value.nestedFlag;
    Nested.refineValues(this);
  }
  get nestedFlag(): boolean {
    return this._nestedFlag;
  }
  set nestedFlag(value: boolean) {
    this._nestedFlag = value;
  }

  /**
   * Serialize message to binary data
   * @param instance message instance
   */
  serializeBinary() {
    const writer = new BinaryWriter();
    Nested.serializeBinaryToWriter(this, writer);
    return writer.getResultBuffer();
  }

  /**
   * Cast message to standard JavaScript object (all non-primitive values are deeply cloned)
   */
  toObject(): Nested.AsObject {
    return {
      nestedFlag: this.nestedFlag
    };
  }

  /**
   * Convenience method to support JSON.stringify(message), replicates the structure of toObject()
   */
  toJSON() {
    return this.toObject();
  }

  /**
   * Cast message to JSON using protobuf JSON notation: https://developers.google.com/protocol-buffers/docs/proto3#json
   * Attention: output differs from toObject() e.g. enums are represented as names and not as numbers, Timestamp is an ISO Date string format etc.
   * If the message itself or some of descendant messages is google.protobuf.Any, you MUST provide a message pool as options. If not, the messagePool is not required
   */
  toProtobufJSON(
    // @ts-ignore
    options?: ToProtobufJSONOptions
  ): Nested.AsProtobufJSON {
    return {
      nestedFlag: this.nestedFlag
    };
  }
}
export module Nested {
  /**
   * Standard JavaScript object representation for Nested
   */
  export interface AsObject {
    nestedFlag: boolean;
  }

  /**
   * Protobuf JSON representation for Nested
   */
  export interface AsProtobufJSON {
    nestedFlag: boolean;
  }
}

/**
 * Message implementation for fixture.presence.Outer
 */
export class Outer implements GrpcMessage {
  static id = 'fixture.presence.Outer';

  /**
   * Deserialize binary data to message
   * @param instance message instance
   */
  static deserializeBinary(bytes: ByteSource) {
    const instance = new Outer();
    Outer.deserializeBinaryFromReader(instance, new BinaryReader(bytes));
    return instance;
  }

  /**
   * Check all the properties and set default protobuf values if necessary
   * @param _instance message instance
   */
  static refineValues(_instance: Outer) {
    _instance.outerFlag = _instance.outerFlag || false;
  }

  /**
   * Deserializes / reads binary message into message instance using provided binary reader
   * @param _instance message instance
   * @param _reader binary reader instance
   */
  static deserializeBinaryFromReader(_instance: Outer, _reader: BinaryReader) {
    while (_reader.nextField()) {
      if (_reader.isEndGroup()) break;

      switch (_reader.getFieldNumber()) {
        case 1:
          _instance.outerFlag = _reader.readBool();
          break;
        default:
          _reader.skipField();
      }
    }

    Outer.refineValues(_instance);
  }

  /**
   * Serializes a message to binary format using provided binary reader
   * @param _instance message instance
   * @param _writer binary writer instance
   */
  static serializeBinaryToWriter(_instance: Outer, _writer: BinaryWriter) {
    if (_instance.outerFlag) {
      _writer.writeBool(1, _instance.outerFlag);
    }
  }

  private _outerFlag: boolean;

  /**
   * Message constructor. Initializes the properties and applies default Protobuf values if necessary
   * @param _value initial values object or instance of Outer to deeply clone from
   */
  constructor(_value?: RecursivePartial<Outer.AsObject>) {
    _value = _value || {};
    this.outerFlag = _value.outerFlag;
    Outer.refineValues(this);
  }
  get outerFlag(): boolean {
    return this._outerFlag;
  }
  set outerFlag(value: boolean) {
    this._outerFlag = value;
  }

  /**
   * Serialize message to binary data
   * @param instance message instance
   */
  serializeBinary() {
    const writer = new BinaryWriter();
    Outer.serializeBinaryToWriter(this, writer);
    return writer.getResultBuffer();
  }

  /**
   * Cast message to standard JavaScript object (all non-primitive values are deeply cloned)
   */
  toObject(): Outer.AsObject {
    return {
      outerFlag: this.outerFlag
    };
  }

  /**
   * Convenience method to support JSON.stringify(message), replicates the structure of toObject()
   */
  toJSON() {
    return this.toObject();
  }

  /**
   * Cast message to JSON using protobuf JSON notation: https://developers.google.com/protocol-buffers/docs/proto3#json
   * Attention: output differs from toObject() e.g. enums are represented as names and not as numbers, Timestamp is an ISO Date string format etc.
   * If the message itself or some of descendant messages is google.protobuf.Any, you MUST provide a message pool as options. If not, the messagePool is not required
   */
  toProtobufJSON(
    // @ts-ignore
    options?: ToProtobufJSONOptions
  ): Outer.AsProtobufJSON {
    return {
      outerFlag: this.outerFlag
    };
  }
}
export module Outer {
  /**
   * Standard JavaScript object representation for Outer
   */
  export interface AsObject {
    outerFlag: boolean;
  }

  /**
   * Protobuf JSON representation for Outer
   */
  export interface AsProtobufJSON {
    outerFlag: boolean;
  }

  /**
   * Message implementation for fixture.presence.Outer.Inner
   */
  export class Inner implements GrpcMessage {
    static id = 'fixture.presence.Outer.Inner';

    /**
     * Deserialize binary data to message
     * @param instance message instance
     */
    static deserializeBinary(bytes: ByteSource) {
      const instance = new Inner();
      Inner.deserializeBinaryFromReader(instance, new BinaryReader(bytes));
      return instance;
    }

    /**
     * Check all the properties and set default protobuf values if necessary
     * @param _instance message instance
     */
    static refineValues(_instance: Inner) {
      _instance.innerText = _instance.innerText || '';
      _instance.plainInnerText = _instance.plainInnerText || '';
    }

    /**
     * Deserializes / reads binary message into message instance using provided binary reader
     * @param _instance message instance
     * @param _reader binary reader instance
     */
    static deserializeBinaryFromReader(
      _instance: Inner,
      _reader: BinaryReader
    ) {
      while (_reader.nextField()) {
        if (_reader.isEndGroup()) break;

        switch (_reader.getFieldNumber()) {
          case 1:
            _instance.innerText = _reader.readString();
            break;
          case 2:
            _instance.plainInnerText = _reader.readString();
            break;
          default:
            _reader.skipField();
        }
      }

      Inner.refineValues(_instance);
    }

    /**
     * Serializes a message to binary format using provided binary reader
     * @param _instance message instance
     * @param _writer binary writer instance
     */
    static serializeBinaryToWriter(_instance: Inner, _writer: BinaryWriter) {
      if (_instance.innerText) {
        _writer.writeString(1, _instance.innerText);
      }
      if (_instance.plainInnerText) {
        _writer.writeString(2, _instance.plainInnerText);
      }
    }

    private _innerText: string;
    private _plainInnerText: string;

    /**
     * Message constructor. Initializes the properties and applies default Protobuf values if necessary
     * @param _value initial values object or instance of Inner to deeply clone from
     */
    constructor(_value?: RecursivePartial<Inner.AsObject>) {
      _value = _value || {};
      this.innerText = _value.innerText;
      this.plainInnerText = _value.plainInnerText;
      Inner.refineValues(this);
    }
    get innerText(): string {
      return this._innerText;
    }
    set innerText(value: string) {
      this._innerText = value;
    }
    get plainInnerText(): string {
      return this._plainInnerText;
    }
    set plainInnerText(value: string) {
      this._plainInnerText = value;
    }

    /**
     * Serialize message to binary data
     * @param instance message instance
     */
    serializeBinary() {
      const writer = new BinaryWriter();
      Inner.serializeBinaryToWriter(this, writer);
      return writer.getResultBuffer();
    }

    /**
     * Cast message to standard JavaScript object (all non-primitive values are deeply cloned)
     */
    toObject(): Inner.AsObject {
      return {
        innerText: this.innerText,
        plainInnerText: this.plainInnerText
      };
    }

    /**
     * Convenience method to support JSON.stringify(message), replicates the structure of toObject()
     */
    toJSON() {
      return this.toObject();
    }

    /**
     * Cast message to JSON using protobuf JSON notation: https://developers.google.com/protocol-buffers/docs/proto3#json
     * Attention: output differs from toObject() e.g. enums are represented as names and not as numbers, Timestamp is an ISO Date string format etc.
     * If the message itself or some of descendant messages is google.protobuf.Any, you MUST provide a message pool as options. If not, the messagePool is not required
     */
    toProtobufJSON(
      // @ts-ignore
      options?: ToProtobufJSONOptions
    ): Inner.AsProtobufJSON {
      return {
        innerText: this.innerText,
        plainInnerText: this.plainInnerText
      };
    }
  }
  export module Inner {
    /**
     * Standard JavaScript object representation for Inner
     */
    export interface AsObject {
      innerText: string;
      plainInnerText: string;
    }

    /**
     * Protobuf JSON representation for Inner
     */
    export interface AsProtobufJSON {
      innerText: string;
      plainInnerText: string;
    }
  }
}

/**
 * Message implementation for fixture.presence.PresenceFixture
 */
export class PresenceFixture implements GrpcMessage {
  static id = 'fixture.presence.PresenceFixture';

  /**
   * Deserialize binary data to message
   * @param instance message instance
   */
  static deserializeBinary(bytes: ByteSource) {
    const instance = new PresenceFixture();
    PresenceFixture.deserializeBinaryFromReader(
      instance,
      new BinaryReader(bytes)
    );
    return instance;
  }

  /**
   * Check all the properties and set default protobuf values if necessary
   * @param _instance message instance
   */
  static refineValues(_instance: PresenceFixture) {
    _instance.optionalFlag = _instance.optionalFlag || false;
    _instance.plainFlag = _instance.plainFlag || false;
    _instance.optionalText = _instance.optionalText || '';
    _instance.plainText = _instance.plainText || '';
    _instance.optionalCount = _instance.optionalCount || 0;
    _instance.optionalView = _instance.optionalView || 0;
    _instance.plainView = _instance.plainView || 0;
    _instance.optionalMessage = _instance.optionalMessage || undefined;
    _instance.plainList = _instance.plainList || [];
    _instance.optionalSize = _instance.optionalSize || '0';
    _instance.optionalRatio = _instance.optionalRatio || 0;
  }

  /**
   * Deserializes / reads binary message into message instance using provided binary reader
   * @param _instance message instance
   * @param _reader binary reader instance
   */
  static deserializeBinaryFromReader(
    _instance: PresenceFixture,
    _reader: BinaryReader
  ) {
    while (_reader.nextField()) {
      if (_reader.isEndGroup()) break;

      switch (_reader.getFieldNumber()) {
        case 1:
          _instance.optionalFlag = _reader.readBool();
          break;
        case 2:
          _instance.plainFlag = _reader.readBool();
          break;
        case 3:
          _instance.optionalText = _reader.readString();
          break;
        case 4:
          _instance.plainText = _reader.readString();
          break;
        case 5:
          _instance.optionalCount = _reader.readInt32();
          break;
        case 6:
          _instance.optionalView = _reader.readEnum();
          break;
        case 7:
          _instance.plainView = _reader.readEnum();
          break;
        case 8:
          _instance.optionalMessage = new Nested();
          _reader.readMessage(
            _instance.optionalMessage,
            Nested.deserializeBinaryFromReader
          );
          break;
        case 9:
          (_instance.plainList = _instance.plainList || []).push(
            _reader.readString()
          );
          break;
        case 12:
          _instance.optionalSize = _reader.readInt64String();
          break;
        case 13:
          _instance.optionalRatio = _reader.readFloat();
          break;
        default:
          _reader.skipField();
      }
    }

    PresenceFixture.refineValues(_instance);
  }

  /**
   * Serializes a message to binary format using provided binary reader
   * @param _instance message instance
   * @param _writer binary writer instance
   */
  static serializeBinaryToWriter(
    _instance: PresenceFixture,
    _writer: BinaryWriter
  ) {
    if (_instance.optionalFlag) {
      _writer.writeBool(1, _instance.optionalFlag);
    }
    if (_instance.plainFlag) {
      _writer.writeBool(2, _instance.plainFlag);
    }
    if (_instance.optionalText) {
      _writer.writeString(3, _instance.optionalText);
    }
    if (_instance.plainText) {
      _writer.writeString(4, _instance.plainText);
    }
    if (_instance.optionalCount) {
      _writer.writeInt32(5, _instance.optionalCount);
    }
    if (_instance.optionalView) {
      _writer.writeEnum(6, _instance.optionalView);
    }
    if (_instance.plainView) {
      _writer.writeEnum(7, _instance.plainView);
    }
    if (_instance.optionalMessage) {
      _writer.writeMessage(
        8,
        _instance.optionalMessage as any,
        Nested.serializeBinaryToWriter
      );
    }
    if (_instance.plainList && _instance.plainList.length) {
      _writer.writeRepeatedString(9, _instance.plainList);
    }
    if (_instance.optionalSize) {
      _writer.writeInt64String(12, _instance.optionalSize);
    }
    if (_instance.optionalRatio) {
      _writer.writeFloat(13, _instance.optionalRatio);
    }
  }

  private _optionalFlag: boolean;
  private _plainFlag: boolean;
  private _optionalText: string;
  private _plainText: string;
  private _optionalCount: number;
  private _optionalView: View;
  private _plainView: View;
  private _optionalMessage?: Nested;
  private _plainList: string[];
  private _optionalSize: string;
  private _optionalRatio: number;

  /**
   * Message constructor. Initializes the properties and applies default Protobuf values if necessary
   * @param _value initial values object or instance of PresenceFixture to deeply clone from
   */
  constructor(_value?: RecursivePartial<PresenceFixture.AsObject>) {
    _value = _value || {};
    this.optionalFlag = _value.optionalFlag;
    this.plainFlag = _value.plainFlag;
    this.optionalText = _value.optionalText;
    this.plainText = _value.plainText;
    this.optionalCount = _value.optionalCount;
    this.optionalView = _value.optionalView;
    this.plainView = _value.plainView;
    this.optionalMessage = _value.optionalMessage
      ? new Nested(_value.optionalMessage)
      : undefined;
    this.plainList = (_value.plainList || []).slice();
    this.optionalSize = _value.optionalSize;
    this.optionalRatio = _value.optionalRatio;
    PresenceFixture.refineValues(this);
  }
  get optionalFlag(): boolean {
    return this._optionalFlag;
  }
  set optionalFlag(value: boolean) {
    this._optionalFlag = value;
  }
  get plainFlag(): boolean {
    return this._plainFlag;
  }
  set plainFlag(value: boolean) {
    this._plainFlag = value;
  }
  get optionalText(): string {
    return this._optionalText;
  }
  set optionalText(value: string) {
    this._optionalText = value;
  }
  get plainText(): string {
    return this._plainText;
  }
  set plainText(value: string) {
    this._plainText = value;
  }
  get optionalCount(): number {
    return this._optionalCount;
  }
  set optionalCount(value: number) {
    this._optionalCount = value;
  }
  get optionalView(): View {
    return this._optionalView;
  }
  set optionalView(value: View) {
    this._optionalView = value;
  }
  get plainView(): View {
    return this._plainView;
  }
  set plainView(value: View) {
    this._plainView = value;
  }
  get optionalMessage(): Nested | undefined {
    return this._optionalMessage;
  }
  set optionalMessage(value: Nested | undefined) {
    this._optionalMessage = value;
  }
  get plainList(): string[] {
    return this._plainList;
  }
  set plainList(value: string[]) {
    this._plainList = value;
  }
  get optionalSize(): string {
    return this._optionalSize;
  }
  set optionalSize(value: string) {
    this._optionalSize = value;
  }
  get optionalRatio(): number {
    return this._optionalRatio;
  }
  set optionalRatio(value: number) {
    this._optionalRatio = value;
  }

  /**
   * Serialize message to binary data
   * @param instance message instance
   */
  serializeBinary() {
    const writer = new BinaryWriter();
    PresenceFixture.serializeBinaryToWriter(this, writer);
    return writer.getResultBuffer();
  }

  /**
   * Cast message to standard JavaScript object (all non-primitive values are deeply cloned)
   */
  toObject(): PresenceFixture.AsObject {
    return {
      optionalFlag: this.optionalFlag,
      plainFlag: this.plainFlag,
      optionalText: this.optionalText,
      plainText: this.plainText,
      optionalCount: this.optionalCount,
      optionalView: this.optionalView,
      plainView: this.plainView,
      optionalMessage: this.optionalMessage
        ? this.optionalMessage.toObject()
        : undefined,
      plainList: (this.plainList || []).slice(),
      optionalSize: this.optionalSize,
      optionalRatio: this.optionalRatio
    };
  }

  /**
   * Convenience method to support JSON.stringify(message), replicates the structure of toObject()
   */
  toJSON() {
    return this.toObject();
  }

  /**
   * Cast message to JSON using protobuf JSON notation: https://developers.google.com/protocol-buffers/docs/proto3#json
   * Attention: output differs from toObject() e.g. enums are represented as names and not as numbers, Timestamp is an ISO Date string format etc.
   * If the message itself or some of descendant messages is google.protobuf.Any, you MUST provide a message pool as options. If not, the messagePool is not required
   */
  toProtobufJSON(
    // @ts-ignore
    options?: ToProtobufJSONOptions
  ): PresenceFixture.AsProtobufJSON {
    return {
      optionalFlag: this.optionalFlag,
      plainFlag: this.plainFlag,
      optionalText: this.optionalText,
      plainText: this.plainText,
      optionalCount: this.optionalCount,
      optionalView:
        View[
          this.optionalView === null || this.optionalView === undefined
            ? 0
            : this.optionalView
        ],
      plainView:
        View[
          this.plainView === null || this.plainView === undefined
            ? 0
            : this.plainView
        ],
      optionalMessage: this.optionalMessage
        ? this.optionalMessage.toProtobufJSON(options)
        : null,
      plainList: (this.plainList || []).slice(),
      optionalSize: this.optionalSize,
      optionalRatio: this.optionalRatio
    };
  }
}
export module PresenceFixture {
  /**
   * Standard JavaScript object representation for PresenceFixture
   */
  export interface AsObject {
    optionalFlag: boolean;
    plainFlag: boolean;
    optionalText: string;
    plainText: string;
    optionalCount: number;
    optionalView: View;
    plainView: View;
    optionalMessage?: Nested.AsObject;
    plainList: string[];
    optionalSize: string;
    optionalRatio: number;
  }

  /**
   * Protobuf JSON representation for PresenceFixture
   */
  export interface AsProtobufJSON {
    optionalFlag: boolean;
    plainFlag: boolean;
    optionalText: string;
    plainText: string;
    optionalCount: number;
    optionalView: string;
    plainView: string;
    optionalMessage: Nested.AsProtobufJSON | null;
    plainList: string[];
    optionalSize: string;
    optionalRatio: number;
  }
}
