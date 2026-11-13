import AppKit
import Foundation

public struct PortalConfig: Codable {
  public var environment: String = "prod"
  public var brain: String = Brain.onDevice.rawValue

  private static var url: URL { PortalPaths.supportDirectory.appendingPathComponent("config.json") }
  public static func load() -> PortalConfig {
    (try? JSONDecoder().decode(PortalConfig.self, from: Data(contentsOf: url))) ?? PortalConfig()
  }
  public func save() { try? JSONEncoder().encode(self).write(to: Self.url, options: [.atomic]) }
}

public struct SceneSummary: Identifiable, Sendable, Hashable {
  public let id: String
  public let name: String
  public let published: Bool
  public let isPublic: Bool
  public let objectCount: Int
  public let url: String
}

public struct Account: Sendable {
  public let nickname: String
  public let strain: Double
  public let strainMax: Double
  public let canCreate: Bool
}

/// One signed-in connection to a TWP environment, shared by the CLI and the
/// app. A line starting with "/" is a direct command and never touches a
/// model; anything else goes to the agent.
public final class Portal: @unchecked Sendable {
  public let environment: PortalEnvironment
  public let auth: PortalAuth
  public let mcp: MCPClient
  public let agent: PortalAgent
  private let emit: @Sendable (PortalEvent) -> Void

  public init(environment: PortalEnvironment, emit: @escaping @Sendable (PortalEvent) -> Void) {
    self.environment = environment
    self.emit = emit
    auth = PortalAuth(environment: environment)
    mcp = MCPClient(auth: auth, endpoint: environment.mcpEndpoint)
    agent = PortalAgent(mcp: mcp, emit: emit)
    agent.origin = environment.originString
    if let brain = Brain(rawValue: PortalConfig.load().brain) { agent.brain = brain }
  }

  public static let help = """
    Type what you want in plain words, or use a command:
      /login            link this Mac to your TWP account (opens the website)
      /logout           unlink and revoke this Mac's access
      /whoami           account and strain
      /scenes [text]    list your scenes, optionally filtered by name
      /scene <id>       details and objects of one scene
      /focus <id>       make "this scene" mean that scene
      /preview [id]     render a picture of a scene
      /open [id]        open a scene in the browser
    Pictures stay on this Mac (the Local shelf) until you upload them:
      /imagine <text> [--background] [x3]     draw a picture, or up to 4 to choose from
      /cutout <name or file>                  remove a picture's background
      /local            what is on the Local shelf
      /import <file>    copy a picture onto the Local shelf
      /upload <name or file> [sticker|background]   send one to your TWP gallery (this spends strain)
      /discard <name>   move a Local picture to the Trash
      /tools            every tool the server offers
      /call <tool> <json>                     run one tool directly
      /brain [on-device|private-cloud]        which Apple model answers
      /clear            forget the conversation so far
    """

  // MARK: Typed helpers (used by the app's sidebar as well as the commands)

  public func account() async throws -> Account {
    let me = try await callJSON("whoami")
    agent.userName = me["nickname"]?.stringValue ?? ""
    return Account(
      nickname: agent.userName, strain: Double(me["strain"]?["current"]?.stringValue ?? "") ?? 0,
      strainMax: Double(me["strain"]?["max"]?.stringValue ?? "") ?? 0, canCreate: me["canCreate"]?.boolValue ?? false)
  }

  public func scenes(query: String? = nil) async throws -> [SceneSummary] {
    let args: JSONValue = (query?.isEmpty ?? true) ? [:] : ["query": .string(query!)]
    return (try await callJSON("list_scenes", args)["scenes"]?.arrayValue ?? []).compactMap { s in
      guard let id = s["id"]?.stringValue else { return nil }
      return SceneSummary(
        id: id, name: s["name"]?.stringValue ?? "(unnamed)", published: s["published"]?.boolValue ?? false,
        isPublic: s["public"]?.boolValue ?? false, objectCount: s["objectCount"]?.intValue ?? 0, url: s["url"]?.stringValue ?? "")
    }
  }

  /// A rendered picture of the scene (webp/png bytes).
  public func preview(sceneId: String) async throws -> Data {
    let result = try await mcp.call("render_scene_preview", ["sceneId": .string(sceneId)])
    guard let image = result.images.first else { throw PortalError.tool(result.text.isEmpty ? "No preview came back." : result.text) }
    return image.data
  }

  private func callJSON(_ tool: String, _ args: JSONValue = [:]) async throws -> JSONValue {
    let result = try await mcp.call(tool, args)
    if result.isError { throw PortalError.tool(result.text) }
    return result.json ?? .null
  }

  // MARK: Command line

  public func handle(_ rawLine: String) async {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return }
    do {
      if line.hasPrefix("/") {
        try await command(line)
      } else {
        guard await auth.isSignedIn else { throw PortalError.notSignedIn }
        let status = PortalAgent.availability(agent.brain)
        guard status.ok else {
          throw PortalError.tool("Apple's \(agent.brain.rawValue) model can't answer right now: \(status.detail). Slash commands still work (/help).")
        }
        emit(.assistant(try await agent.respond(to: line)))
      }
    } catch {
      emit(.error(error.localizedDescription))
    }
  }

  private func command(_ line: String) async throws {
    let parts = line.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
    let name = parts.first?.lowercased() ?? ""
    let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

    switch name {
    case "help", "?": emit(.info(Self.help))
    case "login":
      emit(.info("Opening \(environment.originString) in your browser. Approve there to link this Mac."))
      try await auth.signIn()
      let me = try await account()
      emit(.info("Linked to \(environment.displayName) as \(me.nickname)."))
    case "logout":
      await auth.signOut()
      agent.reset()
      emit(.info("Unlinked from \(environment.displayName)."))
    case "whoami":
      let me = try await account()
      emit(.info("\(me.nickname) on \(environment.displayName) · strain \(Self.trim(me.strain)) of \(Self.trim(me.strainMax))\(me.canCreate ? "" : " · cannot create scenes yet")"))
    case "scenes":
      let list = try await scenes(query: rest)
      if list.isEmpty { emit(.info("No scenes\(rest.isEmpty ? "" : " matching \"\(rest)\"").")); return }
      let rows = list.map { "\($0.id)  \($0.isPublic ? "public " : $0.published ? "listed " : "draft  ")  \(String($0.objectCount).leftPad(3)) obj  \($0.name)" }
      emit(.info("\(list.count) scene\(list.count == 1 ? "" : "s"):\n" + rows.joined(separator: "\n")))
    case "scene":
      let id = try sceneId(rest)
      let s = try await callJSON("get_scene", ["sceneId": .string(id)])
      agent.focusScene = (id, s["name"]?.stringValue ?? id)
      agent.onFocusChange?(id)
      var out = "\(s["name"]?.stringValue ?? "?")  (\(id))\n"
      out += "background \(s["background"]?["width"]?.stringValue ?? "?")×\(s["background"]?["height"]?.stringValue ?? "?") · "
      out += (s["settings"]?["published"]?.boolValue ?? false) ? "published" : "draft"
      let objects = s["objects"]?.arrayValue ?? []
      out += " · \(objects.count) object\(objects.count == 1 ? "" : "s")"
      for o in objects.prefix(40) {
        let what = o["label"]?.stringValue ?? o["kind"]?.stringValue ?? "object"
        let link = o["linkTo"]?.stringValue.map { " → \($0)" } ?? ""
        out += "\n  \(o["id"]?.stringValue ?? "?")  at \(o["x"]?.stringValue ?? "?"),\(o["y"]?.stringValue ?? "?")  \(what)\(link)"
      }
      if objects.count > 40 { out += "\n  …\(objects.count - 40) more" }
      emit(.info(out))
    case "focus":
      let id = try sceneId(rest)
      let s = try await callJSON("get_scene", ["sceneId": .string(id)])
      agent.focusScene = (id, s["name"]?.stringValue ?? id)
      agent.onFocusChange?(id)
      emit(.info("\"This scene\" now means \(agent.focusScene!.name)."))
    case "preview":
      let id = try sceneId(rest)
      emit(.image(try await preview(sceneId: id), caption: "scene \(id)"))
    case "open":
      let id = try sceneId(rest)
      let url = environment.origin.appendingPathComponent(id)
      await MainActor.run { _ = NSWorkspace.shared.open(url) }
    case "local":
      let items = LocalShelf.list()
      if items.isEmpty { emit(.info("The Local shelf is empty. /imagine draws a picture; dropping a file on the window adds one.\n\(LocalShelf.directory.path)")); return }
      let rows = items.map { item in
        "\(item.name.rightPad(34)) \(item.hasAlpha ? "sticker   " : "background") \(String(item.width).leftPad(5))×\(String(item.height).rightPad(5)) \(item.uploads[environment.originString] != nil ? "uploaded" : "local only")"
      }
      emit(.info("\(items.count) picture\(items.count == 1 ? "" : "s") on this Mac (\(LocalShelf.directory.path)):\n" + rows.joined(separator: "\n")))
    case "import":
      guard !rest.isEmpty else { throw PortalError.tool("Usage: /import <file>") }
      let item = try LocalShelf.importFile(URL(fileURLWithPath: Self.path(rest)))
      if let data = try? Data(contentsOf: item.url) { emit(.image(data, caption: item.name)) }
      emit(.info("Added to Local as \(item.name). Not uploaded."))
    case "discard":
      guard let item = LocalShelf.find(rest) else { throw PortalError.tool("No Local picture called \"\(rest)\". See /local.") }
      try LocalShelf.discard(item)
      emit(.info("Moved \(item.name) to the Trash."))
    case "cutout":
      guard !rest.isEmpty else { throw PortalError.tool("Usage: /cutout <Local name or file>") }
      let source = LocalShelf.find(rest)?.url ?? URL(fileURLWithPath: Self.path(rest))
      let label = (source.lastPathComponent as NSString).deletingPathExtension + "-cutout"
      let item = try LocalShelf.save(try ImagePipeline.cutout(try ImagePipeline.load(source)), purpose: .sticker, label: label)
      if let data = try? Data(contentsOf: item.url) { emit(.image(data, caption: item.name)) }
      emit(.info("Saved to Local as \(item.name). Not uploaded; /upload \(item.name) when you want it in your gallery."))
    case "upload":
      var words = rest.split(separator: " ").map(String.init)
      var chosen: ImagePurpose?
      if let last = words.last, let p = ImagePurpose(rawValue: last.lowercased()) {
        chosen = p
        words.removeLast()
      }
      let target = words.joined(separator: " ")
      guard !target.isEmpty else { throw PortalError.tool("Usage: /upload <Local name or file> [sticker|background]") }
      let up: UploadedImage
      let purpose: ImagePurpose
      if let item = LocalShelf.find(target) {
        purpose = chosen ?? item.suggestedPurpose
        up = try await LocalShelf.upload(item, purpose: purpose, mcp: mcp, origin: environment.originString)
      } else {
        purpose = chosen ?? .sticker
        up = try await ImagePipeline.uploadFile(URL(fileURLWithPath: Self.path(target)), purpose: purpose, mcp: mcp)
      }
      if purpose == .sticker, !up.hasAlpha {
        emit(.info("Note: this image has no transparency, so as a sticker it will cover the scene as a rectangle. /cutout removes the background."))
      }
      agent.note("uploaded \(purpose.rawValue) image", up.json.serialized())
      emit(.info("Uploaded as a \(purpose.rawValue), \(up.width)×\(up.height). assetKey \(up.assetKey)"))
    case "imagine":
      var text = rest
      let background = text.contains("--background") || text.contains("--bg")
      text = text.replacingOccurrences(of: "--background", with: "").replacingOccurrences(of: "--bg", with: "")
      var count = 1
      if let match = text.range(of: #"\s+x([1-4])\s*$"#, options: .regularExpression) {
        count = Int(text[match].trimmingCharacters(in: .whitespaces).dropFirst()) ?? 1
        text.removeSubrange(match)
      }
      let prompt = text.trimmingCharacters(in: .whitespaces)
      guard !prompt.isEmpty else { throw PortalError.tool("Usage: /imagine <what to draw> [--background] [x3]") }
      let images = try await agent.imageGenerator(prompt, "illustration", count)
      var names: [String] = []
      for image in images {
        let final = background ? image : try ImagePipeline.cutout(image)
        let item = try LocalShelf.save(final, purpose: background ? .background : .sticker, label: prompt, prompt: prompt)
        if let data = try? Data(contentsOf: item.url) { emit(.image(data, caption: item.name)) }
        names.append(item.name)
      }
      if names.count < count { emit(.info("Image Playground makes one picture at a time; run /imagine again for another.")) }
      agent.note("drew \(background ? "background" : "sticker") picture(s), kept on this Mac, not uploaded", JSONValue.object(["localNames": .array(names.map { .string($0) })]).serialized())
      emit(.info("Saved to Local: \(names.joined(separator: ", ")). Nothing was uploaded. /upload \(names[0]) when you have picked one."))
    case "tools":
      let tools = try await mcp.tools()
      emit(.info(tools.map { "\($0.name.rightPad(24)) \(AgentTool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema, run: { _ in MCPResult(isError: false, text: "", images: []) }).summary)" }.joined(separator: "\n")))
    case "call":
      let bits = rest.split(separator: " ", maxSplits: 1).map(String.init)
      guard let tool = bits.first else { throw PortalError.tool("Usage: /call <tool> {json arguments}") }
      let args = bits.count > 1 ? try JSONValue.parse(bits[1]) : [:]
      // Direct calls skip the model, not the safety prompt.
      if let question = PortalAgent.confirmation(for: tool)?(args), await !agent.confirm(question) {
        emit(.info("Cancelled."))
        return
      }
      let result = try await mcp.call(tool, args)
      for image in result.images { emit(.image(image.data, caption: tool)) }
      if result.isError { emit(.error(result.text)) } else if !result.text.isEmpty { emit(.json(result.json?.serialized(pretty: true) ?? result.text)) }
    case "brain":
      if let brain = Brain(rawValue: rest.lowercased()) {
        agent.brain = brain
        var config = PortalConfig.load()
        config.brain = brain.rawValue
        config.save()
      } else if !rest.isEmpty {
        throw PortalError.tool("Choose on-device or private-cloud.")
      }
      let lines = Brain.allCases.map { b in "\(b == agent.brain ? "●" : "○") \(b.rawValue.rightPad(14)) \(PortalAgent.availability(b).detail)" }
      emit(.info(lines.joined(separator: "\n")))
    case "clear":
      agent.reset()
      emit(.info("Conversation memory cleared."))
    default:
      throw PortalError.tool("Unknown command /\(name). Try /help.")
    }
  }

  private static func path(_ text: String) -> String {
    NSString(string: text.replacingOccurrences(of: "\\ ", with: " ")).expandingTildeInPath
  }

  private func sceneId(_ text: String) throws -> String {
    if !text.isEmpty, text.allSatisfy(\.isNumber) { return text }
    if text.isEmpty, let focus = agent.focusScene { return focus.id }
    throw PortalError.tool(text.isEmpty ? "Which scene? Give an id (see /scenes) or /focus one first." : "\"\(text)\" is not a scene id. Find ids with /scenes.")
  }

  private static func trim(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
  }
}

extension String {
  func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
  func rightPad(_ width: Int) -> String { count >= width ? self : self + String(repeating: " ", count: width - count) }
}
