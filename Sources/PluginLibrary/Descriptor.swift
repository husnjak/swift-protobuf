// Sources/PluginLibrary/Descriptor.swift - Descriptor wrappers
//
// Copyright (c) 2014 - 2017 Apple Inc. and the project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See LICENSE.txt for license information:
// https://github.com/apple/swift-protobuf/blob/master/LICENSE.txt
//
// -----------------------------------------------------------------------------
///
/// This is like Descriptor.{h,cc} in the google/protobuf C++ code, it provides
/// wrappers around the protos to make a more usable object graph for generation
/// and also provides some SwiftProtobuf specific additions that would be useful
/// to anyone generating something that uses SwiftProtobufs (like support the
/// `service` messages). It is *not* the intent for these to eventually be used
/// as part of some reflection or generate message api.
///
// -----------------------------------------------------------------------------

// NOTES:
// 1. `lazy` and `weak` (or `unowned`) doesn't seem to work, so the impl here
//    can't simply keep the `Resolver` and look things up when first accessed
//    instead `bind()` is used to force those lookups to happen.
// 2. Despite the Swift docs seeming to say `unowned` should work, there are
//    compile errors, `weak` ends up being used even though this code doesn't
//    need the zeroing behaviors.  If it did, things will be a little faster
//    as the tracking for weak references wouldn't be needed.

import Foundation
import SwiftProtobuf

public final class DescriptorSet {
  public let files: [FileDescriptor]
  private let registry = Registry()

  public convenience init(proto: Google_Protobuf_FileDescriptorSet) {
    self.init(protos: proto.file)
  }

  public init(protos: [Google_Protobuf_FileDescriptorProto]) {
    let registry = self.registry
    self.files = protos.map { return FileDescriptor(proto: $0, registry: registry) }
  }

  public func lookupFileDescriptor(protoName name: String) -> FileDescriptor {
    return registry.fileDescriptor(name: name)
  }
  public func lookupDescriptor(protoName name: String) -> Descriptor {
    return registry.descriptor(name: name)
  }
  public func lookupEnumDescriptor(protoName name: String) -> EnumDescriptor {
    return registry.enumDescriptor(name: name)
  }
  public func lookupServiceDescriptor(protoName name: String) -> ServiceDescriptor {
    return registry.serviceDescriptor(name: name)
  }
}

public final class FileDescriptor {
  public enum Syntax: String {
    case proto2
    case proto3

    public init?(rawValue: String) {
      switch rawValue {
      case "proto2", "":
        self = .proto2
      case "proto3":
        self = .proto3
      default:
        return nil
      }
    }
  }

  public let proto: Google_Protobuf_FileDescriptorProto
  public var name: String { return proto.name }
  public var package: String { return proto.package }

  public let syntax: Syntax

  public var dependencies: [String] { return proto.dependency }
  public var publicDependencies: [String] { return proto.publicDependency.map { dependencies[Int($0)] } }
  public var weakDependencies: [String] { return proto.weakDependency.map { dependencies[Int($0)] } }

  public let enums: [EnumDescriptor]
  public let messages: [Descriptor]
  public let extensions: [FieldDescriptor]
  public let services: [ServiceDescriptor]

  public var fileOptions: Google_Protobuf_FileOptions { return proto.options }
  public var isDeprecated: Bool { return proto.options.deprecated }

  /// This will be the Swift prefix file option or the prefix to use built
  /// out of the proto package.
  public var swiftTypePrefix: String

  fileprivate init(proto: Google_Protobuf_FileDescriptorProto, registry: Registry) {
    self.proto = proto
    self.syntax = Syntax(rawValue: proto.syntax)!

    let prefix: String
    let protoPackage = proto.package
    if protoPackage.isEmpty {
      prefix = ""
    } else {
      prefix = "." + protoPackage
    }

    swiftTypePrefix = NamingUtils.typePrefix(protoPackage: protoPackage,
                                             fileOptions: proto.options)

    self.enums = proto.enumType.enumeratedMap {
      return EnumDescriptor(proto: $1, index: $0, registry: registry, protoNamePrefix: prefix)
    }
    self.messages = proto.messageType.enumeratedMap {
      return Descriptor(proto: $1, index: $0, registry: registry, protoNamePrefix: prefix)
    }
    self.extensions = proto.extension_p.enumeratedMap {
      return FieldDescriptor(proto: $1, index: $0, registry: registry, isExtension: true)
    }
    self.services = proto.service.enumeratedMap {
      return ServiceDescriptor(proto: $1, index: $0, registry: registry, protoNamePrefix: prefix)
    }

    // Done initializing, register ourselves.
    registry.register(file: self)

    // descriptor.proto documents the files will be in deps order. That means we
    // any external reference will have been in the previous files in the set.
    self.enums.forEach { $0.bind(file: self, registry: registry, containingType: nil) }
    self.messages.forEach { $0.bind(file: self, registry: registry, containingType: nil) }
    self.extensions.forEach { $0.bind(file: self, registry: registry, containingType: nil) }
    self.services.forEach { $0.bind(file: self, registry: registry) }
  }

  // TODO(thomasvl): Eventually hide this and just expose it info off the descriptors so
  // paths aren't needed externally.
  public func sourceCodeInfoLocation(path: IndexPath) -> Google_Protobuf_SourceCodeInfo.Location? {
    guard let location = locationMap[path] else {
      return nil
    }
    return location
  }

  // Lazy so this can be computed on demand, as the imported files won't need
  // comments during generation.
  private lazy var locationMap: [IndexPath:Google_Protobuf_SourceCodeInfo.Location] = {
    var result: [IndexPath:Google_Protobuf_SourceCodeInfo.Location] = [:]
    for loc in self.proto.sourceCodeInfo.location {
      let intList = loc.path.map { return Int($0) }
      result[IndexPath(indexes: intList)] = loc
    }
    return result
  }()
}

public final class Descriptor {
  public let proto: Google_Protobuf_DescriptorProto
  let index: Int
  public let protoName: String
  public private(set) weak var file: FileDescriptor!
  public private(set) weak var containingType: Descriptor?

  public let isMapEntry: Bool

  public let enums: [EnumDescriptor]
  public let messages: [Descriptor]
  public let fields: [FieldDescriptor]
  public let oneofs: [OneofDescriptor]
  public let extensions: [FieldDescriptor]

  fileprivate init(proto: Google_Protobuf_DescriptorProto,
                   index: Int,
                   registry: Registry,
                   protoNamePrefix prefix: String) {
    self.proto = proto
    self.index = index
    let protoName = "\(prefix).\(proto.name)"
    self.protoName = protoName

    isMapEntry = proto.options.mapEntry

    self.enums = proto.enumType.enumeratedMap {
      return EnumDescriptor(proto: $1, index: $0, registry: registry, protoNamePrefix: protoName)
    }
    self.messages = proto.nestedType.enumeratedMap {
      return Descriptor(proto: $1, index: $0, registry: registry, protoNamePrefix: protoName)
    }
    self.fields = proto.field.enumeratedMap {
      return FieldDescriptor(proto: $1, index: $0, registry: registry)
    }
    self.oneofs = proto.oneofDecl.enumeratedMap {
      return OneofDescriptor(proto: $1, index: $0, registry: registry)
    }
    self.extensions = proto.extension_p.enumeratedMap {
      return FieldDescriptor(proto: $1, index: $0, registry: registry, isExtension: true)
    }

    // Done initializing, register ourselves.
    registry.register(message: self)
  }

  fileprivate func bind(file: FileDescriptor, registry: Registry, containingType: Descriptor?) {
    self.file = file
    self.containingType = containingType
    self.enums.forEach { $0.bind(file: file, registry: registry, containingType: self) }
    self.messages.forEach { $0.bind(file: file, registry: registry, containingType: self) }
    self.fields.forEach { $0.bind(file: file, registry: registry, containingType: self) }
    self.oneofs.forEach { $0.bind(registry: registry, containingType: self) }
    self.extensions.forEach { $0.bind(file: file, registry: registry, containingType: self) }
  }
}

public final class EnumDescriptor {
  public let proto: Google_Protobuf_EnumDescriptorProto
  let index: Int
  public let protoName: String
  public private(set) weak var file: FileDescriptor!
  public private(set) weak var containingType: Descriptor?

  // This is lazy so it is they are created only when needed, that way an
  // import doesn't have to do all this work unless the enum is used by
  // the importer.
  public private(set) lazy var values: [EnumValueDescriptor] = {
    var firstValues = [Int32:EnumValueDescriptor]()
    var result = [EnumValueDescriptor]()
    var i = 0
    for p in self.proto.value {
      let aliasing = firstValues[p.number]
      let d = EnumValueDescriptor(proto: p, index: i, enumType: self, aliasing: aliasing)
      result.append(d)
      i += 1

      if let aliasing = aliasing {
        aliasing.aliases.append(d)
      } else {
        firstValues[d.number] = d
      }
    }
    return result
  }()

  fileprivate init(proto: Google_Protobuf_EnumDescriptorProto,
                   index: Int,
                   registry: Registry,
                   protoNamePrefix prefix: String) {
    self.proto = proto
    self.index = index
    self.protoName = "\(prefix).\(proto.name)"

    // Done initializing, register ourselves.
    registry.register(enum: self)
  }

  fileprivate func bind(file: FileDescriptor, registry: Registry, containingType: Descriptor?) {
    self.file = file
    self.containingType = containingType
  }
}

public final class EnumValueDescriptor {
  public let proto: Google_Protobuf_EnumValueDescriptorProto
  let index: Int
  public private(set) weak var enumType: EnumDescriptor!

  public var number: Int32 { return proto.number }

  public private(set) weak var aliasOf: EnumValueDescriptor?
  public fileprivate(set) var aliases: [EnumValueDescriptor] = []

  fileprivate init(proto: Google_Protobuf_EnumValueDescriptorProto,
                   index: Int,
                   enumType: EnumDescriptor,
                   aliasing: EnumValueDescriptor?) {
    self.proto = proto
    self.index = index
    self.enumType = enumType
    aliasOf = aliasing
  }
}

public final class OneofDescriptor {
  public let proto: Google_Protobuf_OneofDescriptorProto
  let index: Int
  public private(set) weak var containingType: Descriptor!

  public var name: String { return proto.name }

  public private(set) lazy var fields: [FieldDescriptor] = {
    let myIndex = Int32(self.index)
    return self.containingType.fields.filter { $0.oneofIndex == myIndex }
  }()

  fileprivate init(proto: Google_Protobuf_OneofDescriptorProto,
                   index: Int,
                   registry: Registry) {
    self.proto = proto
    self.index = index
  }

  fileprivate func bind(registry: Registry, containingType: Descriptor) {
    self.containingType = containingType
  }
}

public final class FieldDescriptor {
  public let proto: Google_Protobuf_FieldDescriptorProto
  let index: Int
  public private(set) weak var file: FileDescriptor!
  /// The Descriptor of the message which this is a field of.  For extensions,
  /// this is the extended type.
  public private(set) weak var containingType: Descriptor!

  public var name: String { return proto.name }
  public var number: Int32 { return proto.number }
  public var label: Google_Protobuf_FieldDescriptorProto.Label { return proto.label }
  public var type: Google_Protobuf_FieldDescriptorProto.TypeEnum { return proto.type }

  /// If this is an extension field.
  public let isExtension: Bool
  /// Extensions can be declared within the scope of another message. If this
  /// is an extension field, then this will be the scope it was declared in
  /// nil if was declared at a global scope.
  public private(set) weak var extensionScope: Descriptor?

  /// The index in a oneof this field is in.
  public var oneofIndex: Int32? {
    if proto.hasOneofIndex {
      return proto.oneofIndex
    }
    return nil
  }
  /// The oneof this field is a member of.
  public private(set) weak var oneof: OneofDescriptor?

  /// When this is a message field, the message's desciptor.
  public private(set) weak var messageType: Descriptor!
  /// When this is a enum field, the enum's desciptor.
  public private(set) weak var enumType: EnumDescriptor!

  fileprivate init(proto: Google_Protobuf_FieldDescriptorProto,
                   index: Int,
                   registry: Registry,
                   isExtension: Bool = false) {
    self.proto = proto
    self.index = index
    self.isExtension = isExtension
  }

  fileprivate func bind(file: FileDescriptor, registry: Registry, containingType: Descriptor?) {
    self.file = file

    assert(isExtension == !proto.extendee.isEmpty)
    if isExtension {
      extensionScope = containingType
      self.containingType = registry.descriptor(name: proto.extendee)
    } else {
      self.containingType = containingType
    }

    switch type {
    case .message:
      messageType = registry.descriptor(name: proto.typeName)
    case .enum:
      enumType = registry.enumDescriptor(name: proto.typeName)
    default:
      break
    }

    if let oneofIndex = oneofIndex {
      oneof = containingType?.oneofs[Int(oneofIndex)]
    }
  }
}

public final class ServiceDescriptor {
  public let proto: Google_Protobuf_ServiceDescriptorProto
  let index: Int
  public let protoName: String
  public private(set) weak var file: FileDescriptor!

  public let methods: [MethodDescriptor]

  fileprivate init(proto: Google_Protobuf_ServiceDescriptorProto,
                   index: Int,
                   registry: Registry,
                   protoNamePrefix prefix: String) {
    self.proto = proto
    self.index = index
    let protoName = "\(prefix).\(proto.name)"
    self.protoName = protoName

    self.methods = proto.method.enumeratedMap {
      return MethodDescriptor(proto: $1, index: $0, registry: registry)
    }

    // Done initializing, register ourselves.
    registry.register(service: self)
  }

  fileprivate func bind(file: FileDescriptor, registry: Registry) {
    self.file = file
    methods.forEach { $0.bind(service: self, registry: registry) }
  }
}

public final class MethodDescriptor {
  public let proto: Google_Protobuf_MethodDescriptorProto
  let index: Int

  public var name: String { return proto.name }

  public private(set) weak var service: ServiceDescriptor!
  public private(set) var inputType: Descriptor!
  public private(set) var outputType: Descriptor!

  fileprivate init(proto: Google_Protobuf_MethodDescriptorProto,
                   index: Int,
                   registry: Registry) {
    self.proto = proto
    self.index = index
  }

  fileprivate func bind(service: ServiceDescriptor, registry: Registry) {
    self.service = service
    inputType = registry.descriptor(name: proto.inputType)
    outputType = registry.descriptor(name: proto.outputType)
  }

}

/// Helper used under the hood to build the mapping tables and look things up.
fileprivate final class Registry {
  private var fileMap = [String:FileDescriptor]()
  private var messageMap = [String:Descriptor]()
  private var enumMap = [String:EnumDescriptor]()
  private var serviceMap = [String:ServiceDescriptor]()

  init() {}

  func register(file: FileDescriptor) {
    fileMap[file.name] = file
  }
  func register(message: Descriptor) {
    messageMap[message.protoName] = message
  }
  func register(enum e: EnumDescriptor) {
    enumMap[e.protoName] = e
  }
  func register(service: ServiceDescriptor) {
    serviceMap[service.protoName] = service
  }

  // These are forced unwraps as the FileDescriptorSet should always be valid from protoc.
  func fileDescriptor(name: String) -> FileDescriptor {
    return fileMap[name]!
  }
  func descriptor(name: String) -> Descriptor {
    return messageMap[name]!
  }
  func enumDescriptor(name: String) -> EnumDescriptor {
    return enumMap[name]!
  }
  func serviceDescriptor(name: String) -> ServiceDescriptor {
    return serviceMap[name]!
  }
}
