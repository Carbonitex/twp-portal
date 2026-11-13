import Foundation

/// A loosely typed JSON tree. MCP tool arguments and results are arbitrary JSON,
/// and scene/object/item ids are 18-digit strings that must never round-trip
/// through Double, so numbers keep their original text.
public enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(String)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(_ any: Any?) {
    switch any {
    case nil, is NSNull: self = .null
    case let n as NSNumber:
      if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.stringValue) }
    case let s as String: self = .string(s)
    case let a as [Any]: self = .array(a.map { JSONValue($0) })
    case let d as [String: Any]: self = .object(d.mapValues { JSONValue($0) })
    default: self = .string(String(describing: any!))
    }
  }

  public static func parse(_ data: Data) throws -> JSONValue {
    JSONValue(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
  }
  public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }

  var foundation: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let b): return b
    case .number(let s):
      if let i = Int64(s) { return i }
      return NSDecimalNumber(string: s)
    case .string(let s): return s
    case .array(let a): return a.map(\.foundation)
    case .object(let o): return o.mapValues(\.foundation)
    }
  }

  public func serialized(pretty: Bool = false) -> String {
    var opts: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
    if pretty { opts.insert(.prettyPrinted) }
    guard let d = try? JSONSerialization.data(withJSONObject: foundation, options: opts) else { return "null" }
    return String(decoding: d, as: UTF8.self)
  }

  public subscript(key: String) -> JSONValue? {
    if case .object(let o) = self { return o[key] }
    return nil
  }
  public subscript(index: Int) -> JSONValue? {
    if case .array(let a) = self, a.indices.contains(index) { return a[index] }
    return nil
  }
  public var stringValue: String? {
    switch self {
    case .string(let s): return s
    case .number(let s): return s
    default: return nil
    }
  }
  public var intValue: Int? {
    switch self {
    case .number(let s): return Int(s) ?? Double(s).map { Int($0) }
    case .string(let s): return Int(s)
    default: return nil
    }
  }
  public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
  public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
  public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
  public var isNull: Bool { self == .null }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(String(value)) }
  public init(nilLiteral: ()) { self = .null }
}
