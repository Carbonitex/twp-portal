import Foundation

/// An optional third brain: any server that speaks the OpenAI chat-completions
/// API with tool calling (Ollama, llama.cpp's llama-server, LM Studio…), run by
/// the user on this Mac or their network. Nothing ships with the portal; Apple's
/// on-device model stays the default. A local model usually has a far larger
/// context window than Apple's 8K, so it is given every tool with full schemas.
public enum LocalBrain {
  /// Default ports of the common runners, tried in order when no address is set.
  static let usualAddresses = ["http://127.0.0.1:11434/v1", "http://127.0.0.1:8080/v1", "http://127.0.0.1:1234/v1"]
  static let defaultContext = 32768

  public struct Status: Sendable {
    public var address: String?
    public var models: [String] = []
    /// The model requests go to: the configured one, or the only one the server offers.
    public var model: String?
    public var ok: Bool { address != nil && model != nil }
    public var detail: String {
      guard let address else { return "no local model server found (start Ollama, llama-server or LM Studio, or set one with /brain server <url>)" }
      guard let model else { return models.isEmpty ? "\(address) offers no models" : "choose a model with /brain model <name> (\(models.count) on \(address))" }
      return "\(model) on \(address)"
    }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var cached = Status()
  /// The last result of `check()`, for menus that cannot wait.
  public static var lastStatus: Status {
    lock.lock()
    defer { lock.unlock() }
    return cached
  }

  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    // A local model can take a while to load and to read a long prompt.
    config.timeoutIntervalForRequest = 900
    config.timeoutIntervalForResource = 1800
    return URLSession(configuration: config)
  }()

  /// "http://host:port" and "http://host:port/v1" both mean the same server.
  static func normalised(_ text: String) -> String? {
    var t = text.trimmingCharacters(in: .whitespaces)
    while t.hasSuffix("/") { t.removeLast() }
    guard let url = URL(string: t), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }
    return url.path.isEmpty ? t + "/v1" : t
  }

  private static func listModels(_ address: String, timeout: TimeInterval) async -> [String]? {
    guard let url = URL(string: address + "/models") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
          let list = (try? JSONValue.parse(data))?["data"]?.arrayValue
    else { return nil }
    // Embedding models cannot chat; leave them out of the choices.
    return list.compactMap { $0["id"]?.stringValue }.filter { !$0.lowercased().contains("embed") }
  }

  /// Finds the server and the model to use. Quick when a server is up; about a second when none is.
  @discardableResult
  public static func check() async -> Status {
    let config = PortalConfig.load()
    var status = Status()
    let candidates = config.brainServer.flatMap(normalised).map { [$0] } ?? usualAddresses
    for address in candidates {
      if let models = await listModels(address, timeout: 1.5) {
        status.address = address
        status.models = models
        break
      }
    }
    if let wanted = config.brainModel, !wanted.isEmpty {
      // A configured name is trusted even if the server does not list it (some servers list nothing useful).
      status.model = status.models.first { $0 == wanted } ?? status.models.first { $0.hasPrefix(wanted) } ?? wanted
    } else if status.models.count == 1 {
      status.model = status.models[0]
    } else {
      status.model = preferred(among: status.models)
    }
    lock.lock()
    cached = status
    lock.unlock()
    return status
  }

  /// With no model chosen, pick one that passed the portal's tool-calling tests (see the README table):
  /// the small gemma4 e4b by default, or the larger and quicker qwen3.6 coding model on a Mac with
  /// memory to spare (it takes about 21 GB). Anything else is left for the user to choose.
  static func preferred(among models: [String]) -> String? {
    let roomy = ProcessInfo.processInfo.physicalMemory >= 64 * 1_073_741_824
    let small = models.first { $0.lowercased().hasPrefix("gemma4:e4b") }
    let large = models.first { $0.lowercased().hasPrefix("qwen3.6") && $0.lowercased().contains("coding") }
    return roomy ? (large ?? small) : small
  }

  public static var contextSize: Int { PortalConfig.load().brainContext ?? defaultContext }

  /// Where a chat-completions request goes: the user's local server, or OpenRouter.
  struct ChatServer {
    var url: URL
    var model: String
    /// Sent with every request (OpenRouter's key and attribution); none for a local server.
    var headers: [String: String] = [:]
    /// "The local model server at …" / "OpenRouter", for messages.
    var name: String
    /// A failed answer in one plain sentence.
    var explain: (_ status: Int, _ json: JSONValue, _ body: Data) -> String
    /// Sees every successful answer (OpenRouter adds up the reported cost).
    var onAnswer: (JSONValue) -> Void = { _ in }
  }

  /// One request to the local server: the model may call tools for several rounds, then answers in words.
  /// `execute` runs a tool call and returns what the model should read back.
  static func respond(system: String, user: String, tools: [AgentTool], progress: @Sendable (String) -> Void,
                      execute: (AgentTool, JSONValue) async -> String) async throws -> String {
    let status = await check()
    guard let address = status.address, let model = status.model, let url = URL(string: address + "/chat/completions") else {
      throw PortalError.tool("The local model can't answer: \(status.detail).")
    }
    let server = ChatServer(url: url, model: model, name: "The local model server at \(address)") { code, json, data in
      let reason = json["error"]?["message"]?.stringValue ?? json["error"]?.stringValue ?? String(decoding: data.prefix(300), as: UTF8.self)
      if reason.lowercased().contains("does not support tools") {
        return "\(model) cannot call tools, so it cannot operate the portal. Choose another with /brain model <name>, or /brain on-device for Apple's."
      }
      return "The local model refused (\(code)): \(reason)"
    }
    return try await run(server, system: system, user: user, tools: tools, progress: progress, execute: execute)
  }

  /// The tool loop itself, shared by every OpenAI-compatible server.
  static func run(_ server: ChatServer, system: String, user: String, tools: [AgentTool], progress: @Sendable (String) -> Void,
                  execute: (AgentTool, JSONValue) async -> String) async throws -> String {
    let model = server.model
    let url = server.url
    let toolList: [JSONValue] = tools.map { tool in
      ["type": "function", "function": ["name": .string(tool.name), "description": .string(String(tool.description.prefix(1200))), "parameters": tool.inputSchema]]
    }
    var messages: [JSONValue] = [["role": "system", "content": .string(system)], ["role": "user", "content": .string(user)]]

    var ranTool = false
    for round in 1...16 {
      try Task.checkCancellation()
      progress(round == 1 ? "\(model) is thinking" : "\(model) is thinking (step \(round))")
      var body: [String: JSONValue] = ["model": .string(model), "messages": .array(messages), "temperature": .number("0.2"), "stream": false]
      if !toolList.isEmpty { body["tools"] = .array(toolList) }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      for (field, value) in server.headers { request.setValue(value, forHTTPHeaderField: field) }
      request.httpBody = Data(JSONValue.object(body).serialized().utf8)
      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await session.data(for: request)
      } catch let error as URLError where error.code == .cancelled {
        throw CancellationError()
      } catch {
        throw PortalError.tool("\(server.name) stopped answering (\(error.localizedDescription)).")
      }
      let json = (try? JSONValue.parse(data)) ?? .null
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      // Some servers (OpenRouter among them) report a failure inside a 200 answer.
      guard code == 200, json["error"] == nil, let message = json["choices"]?[0]?["message"] else {
        throw PortalError.tool(server.explain(code, json, data))
      }
      server.onAnswer(json)
      let calls = message["tool_calls"]?.arrayValue ?? []
      guard !calls.isEmpty else {
        let text = clean(message["content"]?.stringValue ?? "")
        // An empty answer is not a success report: say plainly that the model gave none.
        if text.isEmpty {
          return ranTool
            ? "\(model) finished without saying what it did. The tool results above show what actually happened."
            : "\(model) gave no answer and did nothing. Try rephrasing, or another model (/brain model <name>)."
        }
        return text
      }
      // Echo the assistant's turn back exactly, then answer each call.
      var turn: [String: JSONValue] = ["role": "assistant", "content": .string(message["content"]?.stringValue ?? ""), "tool_calls": .array(calls)]
      // A reasoning model's hidden reasoning must come back with its tool calls, or some providers refuse the next round.
      if let reasoning = message["reasoning_details"], reasoning.arrayValue?.isEmpty == false { turn["reasoning_details"] = reasoning }
      messages.append(.object(turn))
      for call in calls {
        let name = call["function"]?["name"]?.stringValue ?? ""
        let raw = call["function"]?["arguments"]
        // Most servers send the arguments as JSON text; a few send the object itself.
        let args = raw?.objectValue != nil ? raw! : ((try? JSONValue.parse(raw?.stringValue ?? "{}")) ?? [:])
        let output: String
        if let tool = tools.first(where: { $0.name == name }) {
          ranTool = true
          output = await execute(tool, args)
        } else {
          output = "ERROR: there is no tool called \(name). Use only the tools provided."
        }
        var reply: [String: JSONValue] = ["role": "tool", "content": .string(output)]
        if let id = call["id"]?.stringValue { reply["tool_call_id"] = .string(id) }
        messages.append(.object(reply))
      }
    }
    return "\(model) made 16 rounds of tool calls without reaching an answer, so I stopped it. The tool results above show what was and was not done."
  }

  /// Drops a reasoning model's thinking block from the visible answer.
  static func clean(_ text: String) -> String {
    text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
