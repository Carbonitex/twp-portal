import AppKit
import Foundation

public struct PortalConfig: Codable {
  public var environment: String = "prod"
  public var brain: String = Brain.onDevice.rawValue
  // Optional keys stay optional so older config files still decode.
  /// Picture engine: "apple" (default), "qwen-turbo" or "qwen".
  public var pictures: String?
  /// localgen server address; nil means http://127.0.0.1:8740.
  public var picturesServer: String?
  /// Path to the localgen daemon's control socket, when it is not in a usual place.
  public var picturesControl: String?
  /// Unload the Qwen model after this many idle minutes; nil leaves it to the server.
  public var picturesAutoOff: Int?
  /// The `local` brain: an OpenAI-compatible server address (nil tries the usual local ports),
  /// the model to ask for, and its context window in tokens (nil means 32,768).
  public var brainServer: String?
  public var brainModel: String?
  public var brainContext: Int?

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
  /// The folder the scene is filed in; nil at the top level.
  public var folderId: String?
}

public struct SceneFolder: Identifiable, Sendable, Hashable {
  public let id: String
  public let name: String
  /// nil for a top-level folder.
  public let parentId: String?
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
    agent.imageGenerator = { request in try await Pictures.draw(request, progress: { emit(.progress($0)) }) }
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
      /edit <name or file> <what to change>   repaint a picture as instructed (Qwen engine)
      /fill <name or file> <area> <what>      paint something into one part of a picture (Qwen engine);
                                              area is left,top,width,height in percent, or a word like bottom-left
      /pictures [apple|qwen-turbo|qwen]       which engine draws; also: server <url>, unload, auto-off <minutes|never>
      /local            what is on the Local shelf
      /import <file>    copy a picture onto the Local shelf
      /upload <name or file> [sticker|background]   send one to your TWP gallery (this spends strain)
      /discard <name>   move a Local picture to the Trash
      /tools            every tool the server offers
      /call <tool> <json>                     run one tool directly
      /brain [on-device|private-cloud|local]  which model answers; local is your own model server
                                              (Ollama, llama-server, LM Studio): /brain server <url>, /brain model <name>
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
        isPublic: s["public"]?.boolValue ?? false, objectCount: s["objectCount"]?.intValue ?? 0, url: s["url"]?.stringValue ?? "",
        folderId: s["folderId"]?.stringValue)
    }
  }

  /// The user's scene folders (they nest through `parentId`), from the scene map.
  public func folders() async throws -> [SceneFolder] {
    (try await callJSON("get_scene_map")["folders"]?.arrayValue ?? []).compactMap { f in
      guard let id = f["id"]?.stringValue else { return nil }
      return SceneFolder(id: id, name: f["name"]?.stringValue ?? "(unnamed folder)", parentId: f["parentId"]?.stringValue)
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
        if agent.brain == .local {
          let status = await LocalBrain.check()
          guard status.ok else { throw PortalError.tool("The local model can't answer right now: \(status.detail). Slash commands still work (/help), and /brain on-device goes back to Apple's.") }
        } else {
          let status = PortalAgent.availability(agent.brain)
          guard status.ok else {
            throw PortalError.tool("Apple's \(agent.brain.rawValue) model can't answer right now: \(status.detail). Slash commands still work (/help).")
          }
        }
        emit(.assistant(try await agent.respond(to: line)))
      }
    } catch is CancellationError {
      emit(.info("Stopped."))
    } catch let error as URLError where error.code == .cancelled {
      emit(.info("Stopped."))
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
      emit(.info("""
        Opening \(environment.origin.host ?? environment.originString) in your browser.
          1. Sign in there with Discord or Google. No account yet? That creates one for you, free.
          2. Press Approve to link this Mac.
        Take your time. This window waits for you.
        """))
      try await auth.signIn()
      let me = try await account()
      emit(.info("Linked. Welcome, \(me.nickname)! Your scenes are in the sidebar; the suggestions below are a good place to start."))
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
      let engine = PictureEngine.current
      if engine.isQwen { emit(.info("Drawing with \(engine.label)\(engine == .qwen ? " (several minutes a picture)" : " (about a minute a picture)")…")) }
      let images = try await agent.imageGenerator(PictureRequest(prompt: prompt, purpose: background ? .background : .sticker, count: count))
      var names: [String] = []
      for image in images {
        // Qwen draws stickers transparent already; Apple's pictures need their background removed.
        let final = background || ImagePipeline.hasTransparency(image) ? image : try ImagePipeline.cutout(image)
        let item = try LocalShelf.save(final, purpose: background ? .background : .sticker, label: prompt, prompt: prompt)
        if let data = try? Data(contentsOf: item.url) { emit(.image(data, caption: item.name)) }
        names.append(item.name)
      }
      if names.count < count { emit(.info(engine.isQwen ? "Only \(names.count) of \(count) pictures were finished." : "Image Playground makes one picture at a time; run /imagine again for another.")) }
      agent.note("drew \(background ? "background" : "sticker") picture(s), kept on this Mac, not uploaded", JSONValue.object(["localNames": .array(names.map { .string($0) })]).serialized())
      emit(.info("Saved to Local: \(names.joined(separator: ", ")). Nothing was uploaded. /upload \(names[0]) when you have picked one."))
    case "edit":
      let (source, instruction) = try pictureAndRest(rest, usage: "Usage: /edit <Local name or file> <what to change>")
      emit(.info("Editing with \(PictureEngine.current.label)…"))
      let edited = try await Pictures.edit(try ImagePipeline.load(source), instruction: instruction, progress: { [emit] in emit(.progress($0)) })
      let item = try LocalShelf.save(edited, purpose: ImagePipeline.hasTransparency(edited) ? .sticker : .background, label: Self.stem(source) + "-edit", prompt: instruction)
      if let data = try? Data(contentsOf: item.url) { emit(.image(data, caption: item.name)) }
      agent.note("edited a picture, kept on this Mac, not uploaded", JSONValue.object(["localNames": [.string(item.name)]]).serialized())
      emit(.info("Saved to Local as \(item.name). The original is unchanged. Nothing was uploaded."))
    case "fill":
      let usage = "Usage: /fill <Local name or file> <area> <what to paint there>\n  area: left,top,width,height in percent (e.g. 10,60,30,25) or left, right, top, bottom, centre, top-left…"
      let (source, tail) = try pictureAndRest(rest, usage: usage)
      let bits = tail.split(separator: " ", maxSplits: 1).map(String.init)
      guard bits.count == 2, let area = FillArea(bits[0]) else { throw PortalError.tool(usage) }
      emit(.info("Filling with \(PictureEngine.current.label)…"))
      let filled = try await Pictures.fill(try ImagePipeline.load(source), area: area, what: bits[1], progress: { [emit] in emit(.progress($0)) })
      let item = try LocalShelf.save(filled, purpose: .background, label: Self.stem(source) + "-fill", prompt: bits[1])
      if let data = try? Data(contentsOf: item.url) { emit(.image(data, caption: item.name)) }
      agent.note("filled part of a picture, kept on this Mac, not uploaded", JSONValue.object(["localNames": [.string(item.name)]]).serialized())
      emit(.info("Saved to Local as \(item.name). Only the chosen area changed; the original file is untouched. Nothing was uploaded."))
    case "pictures":
      try await pictures(rest)
    case "tools":
      let tools = try await mcp.tools()
      emit(.info(tools.map { "\($0.name.rightPad(24)) \(AgentTool(name: $0.name, description: $0.description, inputSchema: $0.inputSchema, run: { _ in MCPResult(isError: false, text: "", images: []) }).summary)" }.joined(separator: "\n")))
    case "call":
      let bits = rest.split(separator: " ", maxSplits: 1).map(String.init)
      guard let tool = bits.first else { throw PortalError.tool("Usage: /call <tool> {json arguments}") }
      let args = bits.count > 1 ? try JSONValue.parse(bits[1]) : [:]
      // Direct calls skip the model, not the safety prompt.
      switch await PortalAgent.confirmation(for: tool, mcp: mcp)?(args) ?? .proceed {
      case .proceed: break
      case .reject(let reason): throw PortalError.tool(reason)
      case .ask(let question):
        if await !agent.confirm(question) {
          emit(.info("Cancelled."))
          return
        }
      }
      let result = try await mcp.call(tool, args)
      for image in result.images { emit(.image(image.data, caption: tool)) }
      if result.isError { emit(.error(result.text)) } else if !result.text.isEmpty { emit(.json(result.json?.serialized(pretty: true) ?? result.text)) }
    case "brain":
      let words = rest.split(separator: " ").map(String.init)
      var config = PortalConfig.load()
      switch words.first?.lowercased() {
      case nil: break
      case "server":
        if words.count > 1, words[1].lowercased() != "auto" {
          guard LocalBrain.normalised(words[1]) != nil else { throw PortalError.tool("Give an address such as http://127.0.0.1:11434 (Ollama), :8080 (llama-server) or :1234 (LM Studio).") }
          config.brainServer = words[1]
        } else {
          config.brainServer = nil
        }
        config.save()
      case "model":
        config.brainModel = words.count > 1 && words[1].lowercased() != "auto" ? words[1...].joined(separator: " ") : nil
        config.save()
      case "context":
        guard words.count > 1, let size = Int(words[1]), size >= 4096 else { throw PortalError.tool("Usage: /brain context <tokens>, at least 4096 (the default is \(LocalBrain.defaultContext)).") }
        config.brainContext = size
        config.save()
      case let word?:
        guard let brain = Brain(rawValue: word) else { throw PortalError.tool("Choose on-device, private-cloud or local. For local also: /brain server <url>, /brain model <name>, /brain context <tokens>.") }
        agent.brain = brain
        config.brain = brain.rawValue
        config.save()
      }
      let local = await LocalBrain.check()
      var lines = Brain.allCases.map { b in "\(b == agent.brain ? "●" : "○") \(b.rawValue.rightPad(14)) \(PortalAgent.availability(b).detail)" }
      if agent.brain == .local || words.first.map({ ["server", "model", "context", "local"].contains($0.lowercased()) }) ?? false {
        if !local.models.isEmpty { lines.append("models on \(local.address ?? "?"): " + local.models.joined(separator: ", ")) }
        lines.append("local context window: \(LocalBrain.contextSize) tokens (/brain context <tokens> if your server is set up differently)")
      }
      emit(.info(lines.joined(separator: "\n")))
    case "clear":
      agent.reset()
      emit(.info("Conversation memory cleared."))
    default:
      throw PortalError.tool("Unknown command /\(name). Try /help.")
    }
  }

  /// Splits "<picture> <rest>" where the picture is a Local shelf name or a file path (which may hold escaped spaces).
  private func pictureAndRest(_ text: String, usage: String) throws -> (URL, String) {
    let words = text.split(separator: " ").map(String.init)
    guard words.count >= 2 else { throw PortalError.tool(usage) }
    // Longest leading run of words that names a picture wins, so paths with spaces work.
    for n in stride(from: words.count - 1, through: 1, by: -1) {
      let head = words[0..<n].joined(separator: " ")
      let tail = words[n...].joined(separator: " ")
      if n == 1, let item = LocalShelf.find(head) { return (item.url, tail) }
      let file = Self.path(head)
      if file.hasPrefix("/"), FileManager.default.fileExists(atPath: file) { return (URL(fileURLWithPath: file), tail) }
    }
    throw PortalError.tool("No Local picture or file called \"\(words[0])\". See /local.")
  }

  private static func stem(_ url: URL) -> String { (url.lastPathComponent as NSString).deletingPathExtension }

  /// /pictures: choose and manage the picture engine.
  private func pictures(_ rest: String) async throws {
    let words = rest.split(separator: " ").map(String.init)
    var config = PortalConfig.load()
    switch words.first?.lowercased() {
    case nil: break
    case "server":
      if words.count > 1, words[1].lowercased() != "default" {
        guard let url = URL(string: words[1]), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { throw PortalError.tool("Give an address such as http://127.0.0.1:8740.") }
        config.picturesServer = words[1]
      } else {
        config.picturesServer = nil
      }
      config.save()
    case "socket":
      config.picturesControl = words.count > 1 ? words[1...].joined(separator: " ") : nil
      config.save()
    case "unload", "off":
      emit(.info(QwenServer.unload() ? "Unloaded the Qwen model; its memory is free. It loads again on the next picture." : "Nothing was unloaded (the model is not loaded, is busy, or the control socket was not found)."))
      return
    case "auto-off", "autooff":
      guard words.count > 1 else { throw PortalError.tool("Usage: /pictures auto-off <minutes|never>") }
      if ["never", "off", "0"].contains(words[1].lowercased()) {
        config.picturesAutoOff = nil
      } else {
        guard let minutes = Int(words[1]), (1...600).contains(minutes) else { throw PortalError.tool("Give a number of minutes, or never.") }
        config.picturesAutoOff = minutes
      }
      config.save()
    case let word?:
      let aliases = ["playground": "apple", "turbo": "qwen-turbo", "base": "qwen", "qwen-base": "qwen"]
      guard let engine = PictureEngine(rawValue: aliases[word] ?? word) else { throw PortalError.tool("Choose apple, qwen-turbo or qwen. Also: server <url>, unload, auto-off <minutes|never>.") }
      if engine.isQwen, await !QwenServer.reachable() {
        emit(.info("Note: nothing is answering at \(QwenServer.address.absoluteString) right now. The Qwen engines need a localgen server; /pictures server <url> sets another address."))
      }
      config.pictures = engine.rawValue
      config.save()
    }
    let current = PictureEngine.current
    var lines = PictureEngine.allCases.map { "\($0 == current ? "●" : "○") \($0.rawValue.rightPad(11)) \($0.label): \($0.detail)" }
    if current.isQwen {
      let up = await QwenServer.reachable()
      var status = QwenServer.status()
      if !up { status.state = .unreachable }
      lines.append("server \(QwenServer.address.absoluteString) · \(status.summary)")
      lines.append("auto-off: \(config.picturesAutoOff.map { "after \($0) idle minutes (while TWP Portal is open)" } ?? "left to the server")")
    }
    emit(.info(lines.joined(separator: "\n")))
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
