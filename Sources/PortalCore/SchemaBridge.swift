import Foundation
import FoundationModels

/// Turns an MCP tool's JSON Schema into a Foundation Models `GenerationSchema`
/// (built at runtime with `DynamicGenerationSchema`, so no macros), and turns
/// the model's generated arguments back into the JSON the server expects.
///
/// The on-device model has a small context window, so the bridge can also
/// shrink a schema: descriptions are clipped, and anything deeper than
/// `maxDepth` or without a fixed shape is passed as a JSON string instead.
struct SchemaBridge {
  var maxDescription = 90
  var maxDepth = 3
  /// Optional properties beyond this many per object are dropped (required ones always stay).
  var maxOptionalProperties = 8
  /// When set, an optional property is kept only if its name is listed (at any
  /// depth). Small models fill in optional arguments they were never asked
  /// for, so they get just the ones that matter for everyday requests.
  var allowedOptional: Set<String>?

  func generationSchema(toolName: String, inputSchema: JSONValue) throws -> GenerationSchema {
    var counter = 0
    let root = object(inputSchema, name: "\(toolName)_args", depth: 0, counter: &counter)
    return try GenerationSchema(root: root, dependencies: [])
  }

  private func clip(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    let oneLine = text.replacingOccurrences(of: "\n", with: " ")
    return oneLine.count <= maxDescription ? oneLine : String(oneLine.prefix(maxDescription - 1)) + "…"
  }

  private func typeName(_ schema: JSONValue) -> String? {
    if let t = schema["type"]?.stringValue { return t }
    // ["string","null"] style unions: take the first real type.
    return schema["type"]?.arrayValue?.compactMap(\.stringValue).first { $0 != "null" }
  }

  private func object(_ schema: JSONValue, name: String, depth: Int, counter: inout Int) -> DynamicGenerationSchema {
    let props = schema["properties"]?.objectValue ?? [:]
    let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
    // Required first, then optional in name order, capped.
    let optional = props.keys.filter { !required.contains($0) && (allowedOptional?.contains($0) ?? true) }.sorted().prefix(maxOptionalProperties)
    let keys = props.keys.filter { required.contains($0) }.sorted() + optional
    var out: [DynamicGenerationSchema.Property] = []
    for key in keys {
      guard let sub = props[key] else { continue }
      counter += 1
      let (converted, note) = value(sub, name: "\(name)_\(key)_\(counter)", depth: depth + 1, counter: &counter)
      let description = clip([sub["description"]?.stringValue, note].compactMap { $0 }.joined(separator: " "))
      out.append(.init(name: key, description: description, schema: converted, isOptional: !required.contains(key)))
    }
    return DynamicGenerationSchema(name: name, description: nil, properties: out)
  }

  /// Returns the schema plus an optional note appended to the property description.
  private func value(_ schema: JSONValue, name: String, depth: Int, counter: inout Int) -> (DynamicGenerationSchema, String?) {
    if let choices = schema["enum"]?.arrayValue?.compactMap(\.stringValue), !choices.isEmpty {
      return (DynamicGenerationSchema(name: name, anyOf: choices), nil)
    }
    switch typeName(schema) {
    case "string": return (DynamicGenerationSchema(type: String.self), nil)
    case "integer": return (DynamicGenerationSchema(type: Int.self), nil)
    case "number": return (DynamicGenerationSchema(type: Double.self), nil)
    case "boolean": return (DynamicGenerationSchema(type: Bool.self), nil)
    case "array":
      guard depth < maxDepth, let items = schema["items"] else { break }
      let (item, _) = value(items, name: "\(name)_item", depth: depth + 1, counter: &counter)
      return (DynamicGenerationSchema(arrayOf: item, minimumElements: schema["minItems"]?.intValue, maximumElements: schema["maxItems"]?.intValue), nil)
    case "object":
      guard depth < maxDepth, let props = schema["properties"]?.objectValue, !props.isEmpty else { break }
      return (object(schema, name: name, depth: depth, counter: &counter), nil)
    default: break
    }
    // Free-form or too deep: the model writes JSON text and `arguments(from:)` parses it.
    return (DynamicGenerationSchema(type: String.self), "(as JSON text)")
  }

  // MARK: Generated arguments -> JSON for the server

  func arguments(from generated: GeneratedContent, inputSchema: JSONValue) -> JSONValue {
    let raw = (try? JSONValue.parse(generated.jsonString)) ?? [:]
    return reconcile(raw, schema: inputSchema) ?? [:]
  }

  /// Walks the value alongside the real schema: drops nulls and blank optional
  /// strings the model fills in, re-parses JSON-text fields, and keeps ids as strings.
  private func reconcile(_ value: JSONValue, schema: JSONValue) -> JSONValue? {
    switch value {
    case .null: return nil
    case .object(let obj):
      let props = schema["properties"]?.objectValue ?? [:]
      let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
      var out: [String: JSONValue] = [:]
      for (key, sub) in obj {
        if case .string(let s) = sub, s.isEmpty, !required.contains(key) { continue }
        if let fixed = reconcile(sub, schema: props[key] ?? .null) { out[key] = fixed }
      }
      return .object(out)
    case .array(let arr):
      let items = schema["items"] ?? .null
      return .array(arr.compactMap { reconcile($0, schema: items) })
    case .string(let s):
      let type = typeName(schema)
      if type == "string" || schema["enum"] != nil { return value }
      // The property was bridged as JSON text (object/array/untyped): parse it back.
      let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
      if let first = trimmed.first, "{[".contains(first), let parsed = try? JSONValue.parse(trimmed) { return parsed }
      if type == nil { return value }
      if type == "integer" || type == "number", Double(trimmed) != nil { return .number(trimmed) }
      if type == "boolean" { return .bool(trimmed.lowercased() == "true") }
      return value
    case .number(let n):
      // Ids are digit strings; a model that emits one as a number must not lose digits.
      if typeName(schema) == "string" { return .string(n) }
      return value
    case .bool: return value
    }
  }
}
