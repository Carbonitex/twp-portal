import CoreGraphics
import Foundation
import FoundationModels

/// Things the portal shows in its transcript.
public enum PortalEvent: Sendable {
  case info(String)
  case error(String)
  case assistant(String)
  case toolCall(name: String, arguments: String)
  case toolResult(name: String, text: String, isError: Bool)
  case image(Data, caption: String)
  case json(String)
  /// A passing status line while something slow runs ("step 3 of 8"); not part of the transcript.
  case progress(String)
}

/// Which Apple model answers. `onDevice` always works on an Apple Intelligence
/// Mac. `privateCloud` is Apple's larger server model; it needs a managed
/// entitlement from Apple, so it only works in a properly signed build.
public enum Brain: String, Sendable, CaseIterable {
  case onDevice = "on-device"
  case privateCloud = "private-cloud"
}

/// One tool the model may call: an MCP tool on the TWP server, or a local one
/// (image generation, file upload) that runs on this Mac.
struct AgentTool: @unchecked Sendable {
  let name: String
  let description: String
  let inputSchema: JSONValue
  /// Asked of the user before the tool runs; nil means no confirmation.
  var confirmation: ((JSONValue) -> String?)?
  let run: (JSONValue) async throws -> MCPResult

  /// One-line purpose shown to the tool router. The server's descriptions are
  /// written for large models and open with details ("Owner only"), so the
  /// tools the portal knows get a plain line here; unknown tools fall back to
  /// the first sentence of their description.
  static let routerHints: [String: String] = [
    "whoami": "The user's account name and strain balance.",
    "list_scenes": "Find the user's scenes and their sceneIds, optionally by name.",
    "get_scene": "Everything in one scene: its objects with objectIds and positions, background size, links.",
    "get_scene_map": "All the user's scenes, folders and which scenes link to which.",
    "create_scene": "Make a new draft scene. Needs a background assetKey first.",
    "update_scene": "Rename a scene or change its description, background or settings.",
    "publish_scene": "Make a scene public, or turn it back into a private draft.",
    "create_folder": "Make a folder to group scenes.",
    "list_images": "Search existing sticker art by name (curated packs, or the user's own uploads) to get an assetKey.",
    "view_image": "Show one image by assetKey.",
    "import_image_from_url": "Add an image from a web address the user gave. Never guess addresses.",
    "generate_image": "Draw a new picture from a text prompt on this Mac (background or sticker). It is kept on the Local shelf.",
    "upload_image_file": "Upload a picture from this Mac (a Local shelf name or a file path) and get its assetKey.",
    "list_local_pictures": "Pictures already made and waiting on this Mac's Local shelf, with their names.",
    "edit_local_picture": "Change a picture that is on this Mac's Local shelf as instructed (recolour, restyle, add or remove something). Saves a new copy.",
    "place_objects": "Put stickers, items or clickable regions into a scene. Needs sceneId and an assetKey or itemId.",
    "update_objects": "Move, resize, rotate, label or relink objects already in a scene. Needs objectIds from get_scene.",
    "remove_objects": "Delete objects from a scene. Needs objectIds from get_scene.",
    "link_scenes": "Connect two scenes with a clickable exit. Needs both sceneIds.",
    "render_scene_preview": "Take a picture of a scene to show the user how it looks.",
    "forge_item": "Create a new inventory item (prop, key, container, book). Needs an icon assetKey.",
    "list_forge_templates": "The special item types forge_item can make (container, padlock, safe, ticket…).",
    "list_placeable_items": "Items in the user's inventory, with itemIds, that can be placed or given as rewards.",
    "get_container": "What is inside a chest or other container item.",
    "put_in_container": "Move an inventory item into a container.",
    "list_short_links": "The user's short links.",
    "create_short_link": "Give a scene a short web address.",
    "api_catalog": "Search every other website operation (folders, trades, shops, account) when no other tool fits.",
    "api_call": "Run one operation found with api_catalog.",
  ]
  /// Optional arguments the small on-device model is offered, per tool. Tools
  /// not listed keep all of theirs. Everything stays reachable through /call
  /// and through the larger model.
  static let everydayArguments: [String: Set<String>] = [
    "list_scenes": ["query"],
    "list_images": ["source", "query"],
    "get_scene_map": [],
    "create_scene": ["publicNotes"],
    "update_scene": ["name", "publicNotes", "backgroundAssetKey"],
    "place_objects": ["assetKey", "itemId", "nx", "ny", "width", "label"],
    "update_objects": ["nx", "ny", "scale", "rotation", "label"],
    "link_scenes": ["exit", "edge", "bidirectional", "objectId"],
    "forge_item": ["description", "type", "quantity", "tradeable"],
    "list_forge_templates": [],
  ]
  static let recipes = """
    Common combinations:
    - new scene from a file on this Mac: upload_image_file, create_scene
    - new scene with a generated background: generate_image, create_scene
    - add an existing sticker to a scene: list_images, place_objects (plus list_scenes if the scene is only named)
    - add a newly drawn sticker: generate_image, place_objects
    - just draw or try out a picture, not using it yet: generate_image alone
    - use a picture made earlier that is on the Local shelf: list_local_pictures, upload_image_file, then place_objects or create_scene
    - change or repaint a picture that is on the Local shelf: list_local_pictures, edit_local_picture
    - move, resize or delete something in a scene: get_scene, then update_objects or remove_objects
    - connect scenes: list_scenes, link_scenes
    - give players an item: list_placeable_items, place_objects
    """

  var summary: String {
    if let hint = Self.routerHints[name] { return hint }
    let first = description.split(whereSeparator: { ".\n".contains($0) }).first.map(String.init) ?? description
    return first.count > 110 ? String(first.prefix(109)) + "…" : first
  }
  var estimatedTokens: Int { (min(description.count, 320) + inputSchema.serialized().count) / 3 }
}

/// Adapts an `AgentTool` to Foundation Models' `Tool` protocol with a schema
/// built at runtime.
private struct BridgedTool: Tool, @unchecked Sendable {
  typealias Arguments = GeneratedContent
  typealias Output = String
  let tool: AgentTool
  let bridge: SchemaBridge
  let parameters: GenerationSchema
  let outputLimit: Int
  let emit: @Sendable (PortalEvent) -> Void
  let confirm: @Sendable (String) async -> Bool
  let remember: @Sendable (String, String) -> Void
  /// Reports the scene a successful call worked on, so it becomes "this scene".
  let touched: @Sendable (String, String?) -> Void

  var name: String { tool.name }
  var description: String { tool.description.count > 320 ? String(tool.description.prefix(319)) + "…" : tool.description }

  func call(arguments: GeneratedContent) async throws -> String {
    let args = bridge.arguments(from: arguments, inputSchema: tool.inputSchema)
    emit(.toolCall(name: tool.name, arguments: args.serialized()))
    if let question = tool.confirmation?(args), await !confirm(question) {
      emit(.toolResult(name: tool.name, text: "Cancelled by the user.", isError: true))
      return "The user declined this action. Do not retry it; tell them it was not done."
    }
    do {
      let result = try await tool.run(args)
      for image in result.images { emit(.image(image.data, caption: tool.name)) }
      let compact = Compactor.compact(result.text, limit: outputLimit)
      emit(.toolResult(name: tool.name, text: result.text, isError: result.isError))
      if !result.isError {
        remember(tool.name, compact)
        if let id = result.json?["sceneId"]?.stringValue ?? args["sceneId"]?.stringValue ?? args["toSceneId"]?.stringValue {
          touched(id, result.json?["name"]?.stringValue ?? args["name"]?.stringValue)
        }
      }
      if result.text.isEmpty, !result.images.isEmpty { return "Done. The image is now shown to the user." }
      return result.isError ? "ERROR: \(compact)" : compact
    } catch {
      emit(.toolResult(name: tool.name, text: error.localizedDescription, isError: true))
      return "ERROR: \(error.localizedDescription)"
    }
  }
}

/// Shrinks tool output so it fits the model's context: drops noise keys and
/// empties, then trims long arrays, then clips.
enum Compactor {
  static let noise: Set<String> = ["bbox", "thumbnail", "curl", "sceneUrl", "url", "bytes", "note", "howTo", "naturalWidth", "naturalHeight", "nx", "ny"]

  static func compact(_ text: String, limit: Int) -> String {
    guard text.count > limit, var json = try? JSONValue.parse(text) else { return clip(text, limit) }
    json = strip(json)
    var cap = 40
    while json.serialized().count > limit, cap > 2 {
      cap /= 2
      json = trimArrays(json, cap: cap)
    }
    return clip(json.serialized(), limit)
  }

  private static func clip(_ text: String, _ limit: Int) -> String {
    text.count <= limit ? text : String(text.prefix(limit)) + "…[cut, \(text.count - limit) more characters]"
  }

  private static func strip(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let o):
      var out: [String: JSONValue] = [:]
      for (k, v) in o where !noise.contains(k) {
        let s = strip(v)
        switch s {
        case .null: continue
        case .string(let t) where t.isEmpty: continue
        case .array(let a) where a.isEmpty: continue
        case .object(let d) where d.isEmpty: continue
        default: out[k] = s
        }
      }
      return .object(out)
    case .array(let a): return .array(a.map(strip))
    default: return value
    }
  }

  private static func trimArrays(_ value: JSONValue, cap: Int) -> JSONValue {
    switch value {
    case .object(let o): return .object(o.mapValues { trimArrays($0, cap: cap) })
    case .array(let a):
      var kept = a.prefix(cap).map { trimArrays($0, cap: cap) }
      if a.count > cap { kept.append(.string("…\(a.count - cap) more not shown")) }
      return .array(kept)
    default: return value
    }
  }
}

/// The natural-language layer: routes a request to a few tools, lets the model
/// call them, and keeps a short memory between turns.
public final class PortalAgent: @unchecked Sendable {
  public var brain: Brain = .onDevice
  /// Scene the user is looking at in the UI, offered to the model as context.
  public var focusScene: (id: String, name: String)?
  public var userName = ""
  /// Replaced by the app so generation can fall back to the Image Playground sheet.
  public var imageGenerator: @Sendable (PictureRequest) async throws -> [CGImage] = { try await Pictures.draw($0) }
  /// Environment origin, used to remember where a Local picture was uploaded.
  public var origin = ""
  /// Set per turn: true when the routed tools include one that consumes a picture, so generate_image uploads at once.
  private let useGeneratedNow = Flag()
  final class Flag: @unchecked Sendable { var value = false }
  private static let pictureConsumers: Set<String> = ["create_scene", "place_objects", "forge_item", "update_scene"]

  /// Does the request say to put the picture somewhere, rather than only to make it?
  static func asksToUsePicture(_ request: String) -> Bool {
    let pattern = #"\b(add|place|put|use|insert|attach|stick|apply|forge|replace|set)\b|\b(to|in|into|on|onto|for)\s+(this|that|the|my|a|a new)\s+scene\b|\bnew scene\b|\bscene\s+(called|named)\b|\bas (the|a|its) (background|icon)\b"#
    return request.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
  }
  /// Called when a tool call moves the focus to another scene (the app refreshes its preview).
  public var onFocusChange: (@Sendable (String) -> Void)?
  /// Asks the user before a risky action (publish, delete). Default: allow.
  public var confirm: @Sendable (String) async -> Bool = { _ in true }

  private let mcp: MCPClient
  private let emit: @Sendable (PortalEvent) -> Void
  private let lock = NSLock()
  private var turns: [(user: String, reply: String)] = []
  private var notes: [(tool: String, text: String)] = []

  // The model never needs these: local tools cover uploads without base64 or shell access.
  private static let hidden: Set<String> = ["upload_image", "begin_image_upload", "get_upload"]

  public init(mcp: MCPClient, emit: @escaping @Sendable (PortalEvent) -> Void) {
    self.mcp = mcp
    self.emit = emit
  }

  public func reset() {
    lock.lock()
    turns = []
    notes = []
    lock.unlock()
  }

  /// Records something a direct command did (an upload's assetKey, the scene
  /// just opened) so a following plain-language request can refer to it.
  public func note(_ source: String, _ text: String) {
    lock.lock()
    notes.append((source, text))
    if notes.count > 8 { notes.removeFirst() }
    lock.unlock()
  }

  // MARK: Model plumbing

  public static func availability(_ brain: Brain) -> (ok: Bool, detail: String) {
    switch brain {
    case .onDevice:
      switch SystemLanguageModel.default.availability {
      case .available: return (true, "ready")
      case .unavailable(.deviceNotEligible): return (false, "this Mac does not support Apple Intelligence")
      case .unavailable(.appleIntelligenceNotEnabled): return (false, "turn on Apple Intelligence in System Settings")
      case .unavailable(.modelNotReady): return (false, "the model is still downloading")
      case .unavailable: return (false, "unavailable")
      }
    case .privateCloud:
      let model = PrivateCloudComputeLanguageModel()
      return model.isAvailable ? (true, "reported available (needs Apple's Private Cloud Compute entitlement to answer)") : (false, "unavailable")
    }
  }

  public func contextSize() async -> Int {
    switch brain {
    case .onDevice: return SystemLanguageModel.default.contextSize
    case .privateCloud: return (try? await PrivateCloudComputeLanguageModel().contextSize) ?? 32768
    }
  }

  private func session(tools: [any Tool], instructions: String) -> LanguageModelSession {
    switch brain {
    case .onDevice: return LanguageModelSession(model: SystemLanguageModel.default, tools: tools, instructions: instructions)
    case .privateCloud: return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), tools: tools, instructions: instructions)
    }
  }

  // MARK: Tools

  private func allTools() async throws -> [AgentTool] {
    let mcp = self.mcp
    var tools = try await mcp.tools().filter { !Self.hidden.contains($0.name) }.map { t in
      AgentTool(name: t.name, description: t.description, inputSchema: t.inputSchema, confirmation: Self.confirmation(for: t.name)) { args in
        try await mcp.call(t.name, args)
      }
    }
    let generator = imageGenerator
    let origin = self.origin
    let useNow = self.useGeneratedNow
    tools.append(AgentTool(
      name: "generate_image",
      description: "Draw a new picture on this Mac from a text prompt. It is saved to the user's Local shelf. When the result includes assetKey it is uploaded and ready for create_scene (background) or place_objects (sticker); otherwise it stays on this Mac until upload_image_file is called with its name. Stickers get a transparent background.",
      inputSchema: [
        "type": "object", "required": ["prompt", "purpose"],
        "properties": [
          "prompt": ["type": "string", "description": "What to draw, in a short phrase."],
          "purpose": ["type": "string", "enum": ["background", "sticker"]],
          "style": ["type": "string", "enum": ["illustration", "animation", "sketch"]],
        ],
      ],
      run: { [emit] args in
        let purpose = ImagePurpose(rawValue: args["purpose"]?.stringValue ?? "") ?? .sticker
        let prompt = args["prompt"]?.stringValue ?? ""
        guard var image = try await generator(PictureRequest(prompt: prompt, purpose: purpose, style: args["style"]?.stringValue ?? "illustration")).first else { throw PortalError.image("No picture was created.") }
        // The Qwen engine draws stickers transparent already; Apple's pictures need their background removed.
        if purpose == .sticker, !ImagePipeline.hasTransparency(image) { image = try ImagePipeline.cutout(image) }
        let item = try LocalShelf.save(image, purpose: purpose, label: prompt, prompt: prompt)
        if let data = try? Data(contentsOf: item.url) { emit(.image(data, caption: "\(item.name) · saved to Local")) }
        // The picture is uploaded straight away only when this same request goes on to use it in a scene or item.
        guard useNow.value else {
          return MCPResult(isError: false, text: JSONValue.object(["savedAs": .string(item.name), "uploaded": false, "next": "Kept on this Mac only. To use it, call upload_image_file with this name."]).serialized(), images: [])
        }
        let up = try await LocalShelf.upload(item, purpose: purpose, mcp: mcp, origin: origin)
        var out = up.json.objectValue ?? [:]
        out["savedAs"] = .string(item.name)
        return MCPResult(isError: false, text: JSONValue.object(out).serialized(), images: [])
      }))
    tools.append(AgentTool(
      name: "upload_image_file",
      description: "Upload a picture from this Mac to the user's TWP gallery: a file name from the Local shelf (see list_local_pictures) or an absolute file path. Returns assetKey.",
      inputSchema: [
        "type": "object", "required": ["path", "purpose"],
        "properties": ["path": ["type": "string", "description": "Local shelf file name, or an absolute path."], "purpose": ["type": "string", "enum": ["background", "sticker"]]],
      ],
      run: { args in
        let text = args["path"]?.stringValue ?? ""
        let purpose = ImagePurpose(rawValue: args["purpose"]?.stringValue ?? "") ?? .sticker
        let up: UploadedImage
        if let item = LocalShelf.find(text) {
          up = try await LocalShelf.upload(item, purpose: purpose, mcp: mcp, origin: origin)
        } else {
          up = try await ImagePipeline.uploadFile(URL(fileURLWithPath: NSString(string: text).expandingTildeInPath), purpose: purpose, mcp: mcp)
        }
        return MCPResult(isError: false, text: up.json.serialized(), images: [])
      }))
    tools.append(AgentTool(
      name: "list_local_pictures",
      description: "Pictures waiting on this Mac's Local shelf (generated or cut out, not necessarily uploaded): file name, prompt, size, whether transparent, and assetKey if already uploaded.",
      inputSchema: ["type": "object", "properties": [:]],
      run: { _ in
        let rows: [JSONValue] = LocalShelf.list().prefix(30).map { item in
          var row: [String: JSONValue] = ["name": .string(item.name), "transparent": .bool(item.hasAlpha), "size": .string("\(item.width)x\(item.height)")]
          if let prompt = item.prompt { row["prompt"] = .string(prompt) }
          if let key = item.uploads[origin] { row["assetKey"] = .string(key) }
          return .object(row)
        }
        return MCPResult(isError: false, text: JSONValue.object(["pictures": .array(rows)]).serialized(), images: [])
      }))
    // Editing exists only with the optional Qwen engine, so the tool is offered only then.
    if PictureEngine.current.isQwen {
      tools.append(AgentTool(
        name: "edit_local_picture",
        description: "Change a picture on this Mac's Local shelf as instructed, for example recolour it, restyle it, or add or remove something. Saves the result as a new Local picture and returns its name. It is not uploaded.",
        inputSchema: [
          "type": "object", "required": ["name", "instruction"],
          "properties": [
            "name": ["type": "string", "description": "Local shelf file name (see list_local_pictures)."],
            "instruction": ["type": "string", "description": "What to change, in a short sentence."],
          ],
        ],
        run: { [emit] args in
          let name = args["name"]?.stringValue ?? ""
          let instruction = args["instruction"]?.stringValue ?? ""
          guard let item = LocalShelf.find(name) else { throw PortalError.tool("No Local picture called \"\(name)\". Call list_local_pictures for the names.") }
          let edited = try await Pictures.edit(try ImagePipeline.load(item.url), instruction: instruction, progress: { emit(.progress($0)) })
          let saved = try LocalShelf.save(edited, purpose: item.hasAlpha ? .sticker : .background, label: (item.name as NSString).deletingPathExtension + "-edit", prompt: instruction)
          if let data = try? Data(contentsOf: saved.url) { emit(.image(data, caption: "\(saved.name) · saved to Local")) }
          return MCPResult(isError: false, text: JSONValue.object(["savedAs": .string(saved.name), "uploaded": false, "next": "Kept on this Mac only. To use it, call upload_image_file with this name."]).serialized(), images: [])
        }))
    }
    return tools
  }

  /// Actions the user must approve in the moment, whatever the model decides.
  static func confirmation(for tool: String) -> ((JSONValue) -> String?)? {
    switch tool {
    case "publish_scene":
      return { args in
        (args["public"]?.boolValue ?? true) ? "Publish scene \(args["sceneId"]?.stringValue ?? "?") so anyone can visit it?" : nil
      }
    case "remove_objects":
      return { args in "Remove \(args["objectIds"]?.arrayValue?.count ?? 0) object(s) from scene \(args["sceneId"]?.stringValue ?? "?")?" }
    case "api_call":
      return { args in
        (args["confirm"]?.boolValue ?? false) ? "Run the destructive operation \"\(args["op"]?.stringValue ?? "?")\"?" : nil
      }
    default: return nil
    }
  }

  /// Picks the few tools a request needs. The on-device model's whole context is
  /// 8K tokens and the full tool set alone is larger than that, so each turn
  /// carries only what the router selects.
  private func route(_ request: String, tools: [AgentTool], context: String) async -> [AgentTool] {
    let names = tools.map(\.name)
    let catalog = tools.map { "\($0.name): \($0.summary)" }.joined(separator: "\n")
    let pick = DynamicGenerationSchema(name: "ToolChoice", properties: [
      .init(name: "tools", description: "The tools needed, most important first. Empty if none.",
            schema: DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(name: "ToolName", anyOf: names), minimumElements: 0, maximumElements: 4)),
    ])
    guard let schema = try? GenerationSchema(root: pick, dependencies: []) else { return [] }
    let router = session(tools: [], instructions: "You choose which tools an assistant needs to carry out a request in thinkwith.pictures, a world of clickable picture scenes. Include lookup tools when an id or assetKey must be found first. Choose only from the list.\n\(AgentTool.recipes)")
    var options = GenerationOptions()
    options.temperature = 0
    let prompt = "Tools:\n\(catalog)\n\n\(context)Request: \(request)"
    guard let reply = try? await router.respond(to: prompt, schema: schema, options: options),
          let chosen = (try? JSONValue.parse(reply.content.jsonString))?["tools"]?.arrayValue?.compactMap(\.stringValue)
    else { return [] }
    var seen = Set<String>()
    return chosen.compactMap { name in seen.insert(name).inserted ? tools.first { $0.name == name } : nil }
  }

  // MARK: A turn

  public func respond(to request: String) async throws -> String {
    let all = try await allTools()
    let window = await contextSize()
    let small = window < 16000
    let toolBudget = Int(Double(window) * 0.42)

    lock.lock()
    let recentTurns = turns.suffix(small ? 2 : 6)
    let recentNotes = notes.suffix(small ? 2 : 6)
    lock.unlock()

    var context = ""
    if let focusScene { context += "The user is looking at scene \"\(focusScene.name)\" (sceneId \"\(focusScene.id)\"). \"This scene\" means that one.\n" }
    if !recentTurns.isEmpty {
      context += "Earlier in this conversation:\n" + recentTurns.map { "User: \(Self.clip($0.user, 240))\nYou: \(Self.clip($0.reply, 240))" }.joined(separator: "\n") + "\n"
    }
    if !recentNotes.isEmpty {
      context += "Recent tool results:\n" + recentNotes.map { "\($0.tool) -> \(Self.clip($0.text, small ? 500 : 1500))" }.joined(separator: "\n") + "\n"
    }
    if !context.isEmpty { context += "\n" }

    var chosen: [AgentTool]
    if all.reduce(0, { $0 + $1.estimatedTokens }) <= toolBudget {
      chosen = all
    } else {
      chosen = await route(request, tools: all, context: context)
      // A tool named outright in the request is always available.
      for tool in all where request.contains(tool.name) && !chosen.contains(where: { $0.name == tool.name }) { chosen.insert(tool, at: 0) }
      while chosen.count > 1, chosen.reduce(0, { $0 + $1.estimatedTokens }) > toolBudget { chosen.removeLast() }
    }
    // Local first: a drawn picture leaves this Mac only when the user's own words ask for it to be
    // used ("add it to this scene", "new scene with…"). A bare "draw me a mushroom" keeps the picture
    // on the Local shelf, and the tools that would place it are withheld so the model cannot decide otherwise.
    if chosen.contains(where: { $0.name == "generate_image" }) {
      let wantsUse = Self.asksToUsePicture(request)
      if !wantsUse, chosen.count < all.count { chosen.removeAll { Self.pictureConsumers.contains($0.name) } }
      useGeneratedNow.value = wantsUse && chosen.count < all.count
    } else {
      useGeneratedNow.value = false
    }
    if !chosen.isEmpty { emit(.info("tools: " + chosen.map(\.name).joined(separator: ", "))) }

    let instructions = """
      You operate thinkwith.pictures (TWP), a world of clickable picture scenes, for the signed-in user\(userName.isEmpty ? "" : " \(userName)").
      Do what they ask by calling tools. Never invent a sceneId, objectId, itemId or assetKey: look it up with a tool or ask.
      Ids are long digit strings: pass them exactly, in quotes. An objectId is never the same as a sceneId.
      Positions use nx and ny from 0 to 1: nx 0.5, ny 0.5 is the middle; 0,0 is the top-left corner; 1,1 the bottom-right. Keep them between 0.08 and 0.92 so objects stay fully on screen.
      Fill in only the arguments the request calls for; leave every other optional argument out.
      When placing a new sticker, give it a width between 120 and 260 unless the user asks for a size.
      A picture that generate_image returns without an assetKey is saved on this Mac only: say so, and do not place it.
      If a search finds nothing, stop and tell the user; offer to draw the picture instead. Never place an object without an assetKey or itemId.
      Scenes start as private drafts. Do not publish unless the user asks.
      When finished, say what changed in one or two plain sentences. If a tool returns ERROR, explain it simply.
      """

    do {
      let reply = try await run(request: request, context: context, tools: chosen, instructions: instructions, small: small)
      return finish(request, reply)
    } catch let error as LanguageModelError {
      guard case .contextSizeExceeded = error else { throw error }
      // Too much for the window: retry once with no memory and at most two tools.
      emit(.info("That was too much for the model's memory; retrying with less context."))
      let reply = try await run(request: request, context: "", tools: Array(chosen.prefix(2)), instructions: instructions, small: true)
      return finish(request, reply)
    }
  }

  private func run(request: String, context: String, tools: [AgentTool], instructions: String, small: Bool) async throws -> String {
    var bridge = SchemaBridge()
    if small {
      bridge.maxDescription = 70
      bridge.maxOptionalProperties = 6
    } else {
      bridge.maxDescription = 200
      bridge.maxOptionalProperties = 40
      bridge.maxDepth = 5
    }
    let emit = self.emit
    let confirm = self.confirm
    let bridged: [any Tool] = try tools.map { tool in
      var bridge = bridge
      if small { bridge.allowedOptional = AgentTool.everydayArguments[tool.name] }
      return BridgedTool(
        tool: tool, bridge: bridge, parameters: try bridge.generationSchema(toolName: tool.name, inputSchema: tool.inputSchema),
        outputLimit: small ? 1400 : 6000, emit: emit, confirm: confirm,
        remember: { [weak self] name, text in self?.note(name, text) },
        touched: { [weak self] id, name in
          guard let self else { return }
          let known = self.focusScene?.id == id ? self.focusScene?.name : nil
          self.focusScene = (id, name ?? known ?? "scene \(id)")
          self.onFocusChange?(id)
        })
    }
    var options = GenerationOptions()
    options.temperature = 0.2
    let live = session(tools: bridged, instructions: instructions)
    return try await live.respond(to: context + request, options: options).content
  }

  private func finish(_ request: String, _ reply: String) -> String {
    lock.lock()
    turns.append((request, reply))
    if turns.count > 8 { turns.removeFirst() }
    lock.unlock()
    return reply
  }

  private static func clip(_ text: String, _ limit: Int) -> String {
    text.count <= limit ? text : String(text.prefix(limit)) + "…"
  }
}
