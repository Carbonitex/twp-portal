import CoreGraphics
import Foundation
import ImageIO

/// The optional OpenRouter provider: one key that can serve the agent's text
/// (any tool-capable model, through `LocalBrain`'s tool loop) and pictures
/// (the Images API). Off unless the user stores a key and chooses it.
///
/// The address is fixed, so the key is only ever sent to openrouter.ai. Requests
/// are built here from scratch and never carry the TWP sign-in.
public enum OpenRouter {
  static let base = URL(string: "https://openrouter.ai/api/v1")!
  /// Chosen from the live model list on 2026-11-16: reliable tool calls, $0.10 / $0.50 per million tokens (see docs/plan-openrouter.md).
  public static let defaultTextModel = "anthropic/claude-haiku-5.5"
  /// Same family as the local Qwen engine, $0.0184 a picture, takes input pictures (edit and fill). No transparency.
  public static let defaultImageModel = "qwen/qwen-image-2.1-turbo"
  /// Picture models offered by name in the menu and `/pictures model <name>`; any other id still works.
  /// Seedream 5.5, not 5 Flash: Flash refuses a transparent background without an input picture (checked 2026-11-17).
  public static let namedImageModels: [(name: String, id: String, note: String)] = [
    ("qwen", "qwen/qwen-image-2.1-turbo", "Qwen-Image 2.1 Turbo · about $0.018 a picture · stickers are cut out afterwards"),
    ("seedream", "bytedance-seed/seedream-5-5", "Seedream 5.5 · $0.02 a picture, $0.028 an edit · draws stickers truly transparent"),
  ]
  static let keyName = "openrouter-key"
  /// OpenRouter's documented app attribution: the public repository and the app's name.
  static let attribution = ["HTTP-Referer": "https://github.com/Carbonitex/twp-portal", "X-OpenRouter-Title": "TWP Portal", "X-Title": "TWP Portal"]
  static let noKey = "No OpenRouter key is set. Add one with /openrouter key <key> (from openrouter.ai/keys)."

  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    // A picture or a long tool round can take a few minutes; the answer comes in one piece.
    config.timeoutIntervalForRequest = 300
    config.timeoutIntervalForResource = 600
    return URLSession(configuration: config)
  }()

  // MARK: Key

  /// The stored key, or `OPENROUTER_API_KEY` from the environment when none is stored.
  static var key: (value: String, fromEnvironment: Bool)? {
    if let stored = SecretStore.read(keyName) { return (stored, false) }
    if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespaces), !env.isEmpty { return (env, true) }
    return nil
  }
  public static var hasKey: Bool { key != nil }

  static func requireKey() throws -> String {
    guard let key else { throw PortalError.tool(noKey) }
    return key.value
  }

  /// Checks the key with OpenRouter first, so a typo is caught now rather than at the first request.
  public static func storeKey(_ text: String) async throws {
    let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard candidate.count >= 20, !candidate.contains(" ") else { throw PortalError.tool("That does not look like an OpenRouter key (they start with sk-or-).") }
    let (code, json) = try await get("key", key: candidate)
    guard code == 200 else { throw PortalError.tool(code == 401 ? "OpenRouter did not accept that key. Nothing was saved." : explain(code, json, model: nil)) }
    try SecretStore.write(keyName, candidate)
  }

  public static func clearKey() { SecretStore.delete(keyName) }

  static func masked(_ key: String) -> String {
    let prefix = key.hasPrefix("sk-or-v1-") ? "sk-or-v1-" : key.hasPrefix("sk-or-") ? "sk-or-" : ""
    return "\(prefix)…\(key.suffix(4))"
  }

  // MARK: Models

  public static var textModel: String { PortalConfig.load().openrouterModel ?? defaultTextModel }
  public static var imageModel: String { PortalConfig.load().openrouterImageModel ?? defaultImageModel }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var cachedLists: [String: [String: JSONValue]] = [:]

  /// `models` (text) or `images/models`, by id. Public lists, fetched once per run.
  static func list(_ path: String) async throws -> [String: JSONValue] {
    lock.lock()
    let hit = cachedLists[path]
    lock.unlock()
    if let hit { return hit }
    let (code, json) = try await get(path, key: nil)
    guard code == 200, let rows = json["data"]?.arrayValue else { throw PortalError.tool("Could not read OpenRouter's model list (\(code)).") }
    var out: [String: JSONValue] = [:]
    for row in rows { if let id = row["id"]?.stringValue { out[id] = row } }
    lock.lock()
    cachedLists[path] = out
    lock.unlock()
    return out
  }

  static func supportsTools(_ model: JSONValue) -> Bool {
    model["supported_parameters"]?.arrayValue?.contains(.string("tools")) ?? false
  }

  /// Checks a text model id: it must exist and call tools. Returns the reason it cannot be used, or nil.
  public static func problem(withTextModel id: String) async -> String? {
    guard let models = try? await list("models") else { return nil }  // Offline: trust the id; the first request will say.
    guard let model = models[id] else {
      let close = models.keys.filter { $0.localizedCaseInsensitiveContains(id) }.sorted().prefix(5)
      return "OpenRouter has no model \"\(id)\".\(close.isEmpty ? " Model ids look like anthropic/claude-haiku-5.5." : " Did you mean: \(close.joined(separator: ", "))?")"
    }
    return supportsTools(model) ? nil : "\(id) cannot call tools, so it cannot operate the portal. Choose one whose OpenRouter page lists tool support."
  }

  /// Checks a picture model id: it must be one the Images API serves.
  public static func problem(withImageModel id: String) async -> String? {
    guard let models = try? await list("images/models") else { return nil }
    guard models[id] != nil else {
      let close = models.keys.filter { $0.localizedCaseInsensitiveContains(id) }.sorted().prefix(5)
      return "OpenRouter has no picture model \"\(id)\".\(close.isEmpty ? " Ids look like \(defaultImageModel)." : " Did you mean: \(close.joined(separator: ", "))?")"
    }
    return nil
  }

  /// The model's own window, capped: past that the portal gains nothing and the requests only cost more.
  public static var contextSize: Int {
    lock.lock()
    let model = cachedLists["models"]?[textModel]
    lock.unlock()
    return min(model?["context_length"]?.intValue ?? 131_072, 200_000)
  }

  // MARK: Errors

  /// Turns an OpenRouter failure into one plain sentence.
  static func explain(_ code: Int, _ json: JSONValue, model: String?) -> String {
    let error = json["error"]
    let status = error?["code"]?.intValue ?? code
    let message = error?["message"]?.stringValue ?? ""
    let meta = error?["metadata"]
    let lower = message.lowercased()
    let who = model ?? "The model"
    if lower.contains("tool use") || lower.contains("support tool") || (lower.contains("tool") && lower.contains("not support")) {
      return "\(who) cannot call tools, so it cannot operate the portal. Choose another with /brain model <id>."
    }
    switch status {
    case 401: return "OpenRouter did not accept the key (it may have been revoked). Set a new one with /openrouter key <key>."
    case 402:
      if meta?["limit_source"]?.stringValue == "openrouter_key_limit" { return "This OpenRouter key has reached its spending limit. Raise it at openrouter.ai/keys, or use another key." }
      return "The OpenRouter account is out of credit. Add credit at openrouter.ai/credits and try again."
    case 403:
      if let reasons = meta?["reasons"]?.arrayValue?.compactMap(\.stringValue), !reasons.isEmpty {
        return "The request was refused by content moderation (\(reasons.joined(separator: ", "))). Try different wording."
      }
      if let source = meta?["limit_source"]?.stringValue, source.contains("budget") {
        return "An OpenRouter budget limit stopped this request\(meta?["resets_at"]?.stringValue.map { "; it resets at \($0)" } ?? ""). Raise it on openrouter.ai."
      }
      return "OpenRouter refused the request\(message.isEmpty ? "" : ": \(message)")."
    case 408: return "\(who) took too long and OpenRouter gave up. Try again, or a faster model."
    case 429:
      if lower.contains("free") { return "The free-model limit is used up for now. Try again later, or choose a paid model." }
      return "OpenRouter is rate limiting this key. Wait a minute and try again."
    case 404: return message.isEmpty ? "OpenRouter has no such model. Check the id with /openrouter." : "OpenRouter: \(message)"
    case 502: return "\(who) is down or gave a broken answer. Try again, or choose another model."
    case 503: return "No provider can serve \(model ?? "this model") right now. Try again later, or choose another model."
    default:
      if lower.contains("safety") || lower.contains("moderat") || lower.contains("content policy") || lower.contains("refus") {
        return "\(who) refused this request on content grounds. Try different wording."
      }
      return message.isEmpty ? "OpenRouter answered \(code) without a reason." : "OpenRouter could not do that (\(status)): \(message)"
    }
  }

  // MARK: Text

  /// The `LocalBrain` loop pointed at OpenRouter.
  static func chatServer() throws -> LocalBrain.ChatServer {
    let key = try requireKey()
    let model = textModel
    var headers = attribution
    headers["Authorization"] = "Bearer \(key)"
    var server = LocalBrain.ChatServer(url: base.appendingPathComponent("chat/completions"), model: model, headers: headers, name: "OpenRouter") { code, json, _ in
      explain(code, json, model: model)
    }
    server.onAnswer = { record($0) }
    return server
  }

  /// One short request through the same tool loop, with one harmless local tool: shows that the key,
  /// the model and its tool calling work, without a TWP account. Costs a fraction of a cent.
  public static func selfTest(progress: @Sendable (String) -> Void) async throws -> (reply: String, toolRan: Bool) {
    let ran = Flag()
    let tool = AgentTool(
      name: "shelf_count", description: "How many pictures are on the user's Local shelf.",
      inputSchema: ["type": "object", "properties": [:]],
      run: { _ in MCPResult(isError: false, text: "{\"pictures\": 7}", images: []) })
    let reply = try await LocalBrain.run(
      try chatServer(), system: "You answer by calling tools when one fits. Reply in one short sentence.",
      user: "How many pictures are on my Local shelf?", tools: [tool], progress: progress
    ) { tool, _ in
      ran.value = true
      return (try? await tool.run([:]).text) ?? ""
    }
    return (reply, ran.value)
  }
  final class Flag: @unchecked Sendable { var value = false }

  // MARK: Status

  /// For /openrouter: key, models, credit.
  public static func statusLines() async -> [String] {
    var lines: [String] = []
    guard let key else {
      return [noKey, "text model: \(textModel) · picture model: \(imageModel)"]
    }
    lines.append("key: \(masked(key.value)) \(key.fromEnvironment ? "(from OPENROUTER_API_KEY; not stored)" : "(stored on this Mac)")")
    lines.append("text model: \(textModel)\(PortalConfig.load().openrouterModel == nil ? " (default)" : "") · /brain model <id>")
    lines.append("picture model: \(imageModel)\(PortalConfig.load().openrouterImageModel == nil ? " (default)" : "") · /pictures model <id>")
    if let (code, json) = try? await get("key", key: key.value) {
      if code == 200, let data = json["data"] {
        if let remaining = Double(data["limit_remaining"]?.stringValue ?? ""), let limit = Double(data["limit"]?.stringValue ?? "") {
          lines.append("this key: $\(money(remaining)) left of its $\(money(limit)) limit")
        }
      } else {
        lines.append(explain(code, json, model: nil))
      }
    }
    if let (code, json) = try? await get("credits", key: key.value), code == 200,
       let total = Double(json["data"]?["total_credits"]?.stringValue ?? ""), let used = Double(json["data"]?["total_usage"]?.stringValue ?? "") {
      lines.append("account credit: $\(money(total - used))")
    }
    let spent = spentThisRun
    if spent > 0 { lines.append("spent by this \(ProcessInfo.processInfo.processName == "twp" ? "command" : "session"): $\(String(format: "%.4f", spent))") }
    return lines
  }

  private static func money(_ value: Double) -> String { String(format: "%.2f", value) }

  nonisolated(unsafe) private static var spent = 0.0
  static var spentThisRun: Double {
    lock.lock()
    defer { lock.unlock() }
    return spent
  }
  /// Adds an answer's reported cost (`usage.cost`) to the running total.
  static func record(_ json: JSONValue) {
    guard let cost = Double(json["usage"]?["cost"]?.stringValue ?? "") else { return }
    lock.lock()
    spent += cost
    lock.unlock()
  }

  // MARK: Pictures

  /// One picture from the Images API. `ratio` is width / height; `references` are input pictures (PNG bytes).
  /// Only the parameters the model lists are sent.
  static func image(prompt: String, ratio: Double, transparent: Bool, references: [Data] = []) async throws -> CGImage {
    let key = try requireKey()
    let model = imageModel
    let info = (try? await list("images/models"))?[model]
    let params = info?["supported_parameters"]
    func values(_ name: String) -> [String] { params?[name]?["values"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    var body: [String: JSONValue] = ["model": .string(model), "prompt": .string(prompt)]
    if let aspect = nearestAspect(ratio, among: values("aspect_ratio")) { body["aspect_ratio"] = .string(aspect) }
    if values("resolution").contains("1K") { body["resolution"] = "1K" }
    if values("output_format").contains("png") { body["output_format"] = "png" }
    if transparent, values("background").contains("transparent") { body["background"] = "transparent" }
    if !references.isEmpty {
      let takesPictures = info == nil || info?["architecture"]?["input_modalities"]?.arrayValue?.contains(.string("image")) == true
      guard takesPictures, (params?["input_references"]?["max"]?.intValue ?? 1) > 0 else {
        throw PortalError.image("\(model) cannot take a picture as input, so it cannot edit or fill. Choose another with /pictures model <id>.")
      }
      body["input_references"] = .array(references.map { ["type": "image_url", "image_url": ["url": .string("data:image/png;base64," + $0.base64EncodedString())]] })
    }

    var request = URLRequest(url: base.appendingPathComponent("images"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    for (field, value) in attribution { request.setValue(value, forHTTPHeaderField: field) }
    request.httpBody = Data(JSONValue.object(body).serialized().utf8)
    let (code, json) = try await send(request)
    guard code == 200, json["error"] == nil else { throw PortalError.image(explain(code, json, model: model)) }
    record(json)
    guard let first = json["data"]?[0] else {
      throw PortalError.image("\(model) sent no picture back. It may have refused the prompt; try different wording.")
    }
    var bytes = first["b64_json"]?.stringValue.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
    // A hosted copy instead of inline bytes: fetched without any key or sign-in.
    if bytes == nil, let link = first["url"]?.stringValue, let url = URL(string: link), url.scheme == "https" {
      bytes = try? await URLSession.shared.data(from: url).0
    }
    guard let bytes, let source = CGImageSourceCreateWithData(bytes as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw PortalError.image("\(model) answered with something that is not a picture.")
    }
    return image
  }

  /// The listed aspect ratio ("3:2") closest to `ratio`, or nil when the model lists none.
  static func nearestAspect(_ ratio: Double, among choices: [String]) -> String? {
    let parsed: [(String, Double)] = choices.compactMap { text in
      let parts = text.split(separator: ":").compactMap { Double($0) }
      return parts.count == 2 && parts[1] > 0 ? (text, parts[0] / parts[1]) : nil
    }
    return parsed.min { abs(log($0.1 / ratio)) < abs(log($1.1 / ratio)) }?.0
  }

  // MARK: HTTP

  private static func get(_ path: String, key: String?) async throws -> (Int, JSONValue) {
    var request = URLRequest(url: base.appendingPathComponent(path))
    request.timeoutInterval = 20
    if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    for (field, value) in attribution { request.setValue(value, forHTTPHeaderField: field) }
    return try await send(request)
  }

  private static func send(_ request: URLRequest) async throws -> (Int, JSONValue) {
    do {
      let (data, response) = try await session.data(for: request)
      return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONValue.parse(data)) ?? .null)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError {
      throw PortalError.tool("Could not reach OpenRouter (\(error.localizedDescription)).")
    }
  }
}
