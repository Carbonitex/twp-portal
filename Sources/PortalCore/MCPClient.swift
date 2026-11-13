import Foundation

public struct MCPTool: Sendable {
  public let name: String
  public let description: String
  public let inputSchema: JSONValue
}

public struct MCPImage: Sendable {
  public let data: Data
  public let mimeType: String
}

public struct MCPResult: Sendable {
  public let isError: Bool
  public let text: String
  public let images: [MCPImage]

  /// The text block parsed as JSON, when it is JSON (TWP tools return a JSON text block).
  public var json: JSONValue? { try? JSONValue.parse(text) }
}

/// Client for the TWP Scene Builder MCP endpoint (`/api/twp/mcp`). The server is
/// stateless JSON-RPC over POST: no sessions and no SSE, one request per call.
public actor MCPClient {
  public let endpoint: URL
  private let auth: PortalAuth
  private let session: URLSession
  private var nextId = 1
  private var cachedTools: [MCPTool]?
  private static let protocolVersion = "2025-06-18"

  public init(auth: PortalAuth, endpoint: URL, session: URLSession = .shared) {
    self.auth = auth
    self.endpoint = endpoint
    self.session = session
  }

  public func tools(refresh: Bool = false) async throws -> [MCPTool] {
    if let cachedTools, !refresh { return cachedTools }
    let result = try await rpc("tools/list", [:])
    let list = (result["tools"]?.arrayValue ?? []).compactMap { t -> MCPTool? in
      guard let name = t["name"]?.stringValue else { return nil }
      return MCPTool(name: name, description: t["description"]?.stringValue ?? "", inputSchema: t["inputSchema"] ?? ["type": "object"])
    }
    cachedTools = list
    return list
  }

  public func call(_ name: String, _ arguments: JSONValue = [:]) async throws -> MCPResult {
    let result = try await rpc("tools/call", ["name": .string(name), "arguments": arguments])
    var texts: [String] = []
    var images: [MCPImage] = []
    for block in result["content"]?.arrayValue ?? [] {
      switch block["type"]?.stringValue {
      case "text": if let t = block["text"]?.stringValue { texts.append(t) }
      case "image":
        if let b64 = block["data"]?.stringValue, let data = Data(base64Encoded: b64) {
          images.append(MCPImage(data: data, mimeType: block["mimeType"]?.stringValue ?? "image/webp"))
        }
      default: break
      }
    }
    return MCPResult(isError: result["isError"]?.boolValue ?? false, text: texts.joined(separator: "\n"), images: images)
  }

  private func rpc(_ method: String, _ params: JSONValue) async throws -> JSONValue {
    let id = nextId
    nextId += 1
    let body: JSONValue = ["jsonrpc": "2.0", "id": .number(String(id)), "method": .string(method), "params": params]

    func send(_ token: String) async throws -> (Data, Int) {
      var req = URLRequest(url: endpoint)
      req.httpMethod = "POST"
      req.timeoutInterval = 120
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.setValue("application/json", forHTTPHeaderField: "Accept")
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      req.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
      req.setValue("TWPPortal-mac/0.1", forHTTPHeaderField: "User-Agent")
      req.httpBody = Data(body.serialized().utf8)
      let (data, resp) = try await session.data(for: req)
      return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    var (data, status) = try await send(try await auth.accessToken())
    if status == 401 {
      // The server may have revoked the access token early; one forced refresh, then give up.
      (data, status) = try await send(try await auth.accessToken(forceRefresh: true))
      if status == 401 { throw PortalError.notSignedIn }
    }
    let json = (try? JSONValue.parse(data)) ?? .null
    if let err = json["error"] {
      throw PortalError.protocolError(err["message"]?.stringValue ?? "The server rejected the request (\(status)).")
    }
    guard (200..<300).contains(status), let result = json["result"] else {
      throw PortalError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
    }
    return result
  }
}
