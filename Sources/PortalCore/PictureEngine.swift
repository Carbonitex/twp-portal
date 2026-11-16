import CoreGraphics
import CoreImage
import Foundation

/// What draws pictures. Apple's Image Playground is the default and needs
/// nothing installed. The Qwen engines are optional: they call a localgen
/// server (Qwen-Image 2.1) running on this Mac or the local network, and add
/// editing and filling, which Image Playground cannot do. `openrouter` is also
/// optional: a hosted picture model through the user's OpenRouter key.
public enum PictureEngine: String, Sendable, CaseIterable {
  case apple
  case qwenTurbo = "qwen-turbo"
  case qwen
  case openrouter

  public var label: String {
    switch self {
    case .apple: return "Apple Image Playground"
    case .qwenTurbo: return "Qwen-Image 2.1 Turbo"
    case .qwen: return "Qwen-Image 2.1"
    case .openrouter: return "OpenRouter (\(OpenRouter.imageModel))"
    }
  }
  public var shortLabel: String {
    switch self {
    case .apple: return "Apple"
    case .qwenTurbo: return "Qwen Turbo"
    case .qwen: return "Qwen 2.1"
    case .openrouter: return "OpenRouter"
    }
  }
  public var detail: String {
    switch self {
    case .apple: return "built in; one picture at a time, no editing"
    case .qwenTurbo: return "local server, about a minute a picture; edit and fill"
    case .qwen: return "local server, best quality, several minutes a picture; edit and fill"
    case .openrouter: return "hosted, paid per picture on your OpenRouter key; pictures leave this Mac; edit and fill"
    }
  }
  /// The optional localgen server engines (status light, unloading).
  public var isQwen: Bool { self == .qwen || self == .qwenTurbo }
  /// Every engine but Image Playground draws by itself (no sheet) and can edit and fill.
  public var canEdit: Bool { self != .apple }
  /// The model name the localgen API expects.
  var serverModel: String { self == .qwen ? "base" : "turbo" }

  public static var current: PictureEngine { PictureEngine(rawValue: PortalConfig.load().pictures ?? "") ?? .apple }
}

public struct PictureRequest: Sendable {
  public var prompt: String
  public var purpose: ImagePurpose
  public var style: String
  public var count: Int
  /// Delivered size; nil picks a square sticker or a landscape background.
  public var size: (width: Int, height: Int)?

  public init(prompt: String, purpose: ImagePurpose, style: String = "illustration", count: Int = 1, size: (width: Int, height: Int)? = nil) {
    self.prompt = prompt
    self.purpose = purpose
    self.style = style
    self.count = count
    self.size = size
  }
}

/// Where a fill goes: fractions of the picture, measured from its top-left corner.
public struct FillArea: Sendable, Equatable {
  public var x: Double, y: Double, width: Double, height: Double
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  /// "10,60,30,25" (percent: left, top, width, height) or a word such as "left" or "bottom-right".
  public init?(_ text: String) {
    let named: [String: (Double, Double, Double, Double)] = [
      "left": (0, 0, 0.5, 1), "right": (0.5, 0, 0.5, 1), "top": (0, 0, 1, 0.5), "bottom": (0, 0.5, 1, 0.5),
      "center": (0.25, 0.25, 0.5, 0.5), "centre": (0.25, 0.25, 0.5, 0.5), "middle": (0.25, 0.25, 0.5, 0.5),
      "top-left": (0, 0, 0.5, 0.5), "top-right": (0.5, 0, 0.5, 0.5), "bottom-left": (0, 0.5, 0.5, 0.5), "bottom-right": (0.5, 0.5, 0.5, 0.5),
    ]
    if let n = named[text.lowercased()] {
      self.init(x: n.0, y: n.1, width: n.2, height: n.3)
      return
    }
    let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: " %"))) }
    guard parts.count == 4, text.split(separator: ",").count == 4 else { return nil }
    let x = min(max(parts[0], 0), 99) / 100, y = min(max(parts[1], 0), 99) / 100
    let w = min(parts[2] / 100, 1 - x), h = min(parts[3] / 100, 1 - y)
    guard w >= 0.02, h >= 0.02 else { return nil }
    self.init(x: x, y: y, width: w, height: h)
  }

  public var text: String { [x, y, width, height].map { String(Int(($0 * 100).rounded())) }.joined(separator: ",") }
}

/// What the Qwen server is doing, for the status light.
public struct QwenStatus: Sendable, Equatable {
  public enum State: Sendable, Equatable {
    /// Nothing answers at the server address.
    case unreachable
    /// The server answers, but its control socket was not found, so the loaded state is not known.
    case unknown
    /// The server is up and the model is not in memory.
    case unloaded
    case loaded
    case busy
  }
  public var state: State
  /// "turbo" or "base" when loaded.
  public var variant: String?
  public var idleSeconds: Int?
  public var memoryGB: Double?
  /// "step 3 of 8", "loading", "writing prompt"… while a picture is being made.
  public var progress: String?

  public init(state: State) { self.state = state }

  public var summary: String {
    switch state {
    case .unreachable: return "The Qwen server is not answering"
    case .unknown: return "Qwen server is up (loaded state unknown: control socket not found)"
    case .unloaded: return "Qwen model is not loaded (loads on the next picture)"
    case .loaded:
      let idle = idleSeconds.map { $0 < 90 ? "idle \($0) s" : "idle \($0 / 60) min" } ?? "idle"
      return "Qwen \(variant ?? "model") loaded · \(idle)\(memoryGB.map { " · about \(Int($0)) GB" } ?? "")"
    case .busy: return "Qwen \(variant ?? "model") is working\(progress.map { " · \($0)" } ?? "")"
    }
  }
}

/// Client for a localgen server: `POST /generate-image` over HTTP for pictures,
/// and the daemon's unix socket (same Mac only) for status and unloading.
public enum QwenServer {
  public static let defaultAddress = "http://127.0.0.1:8740"
  static let engineName = "qwen-image"

  public static var address: URL {
    URL(string: PortalConfig.load().picturesServer ?? "") ?? URL(string: defaultAddress)!
  }

  /// The daemon's control socket: the configured path, `$LOCALGEN_HOME`, or `~/local-generators`.
  public static var controlSocket: String? {
    let home = NSHomeDirectory()
    var candidates: [String] = []
    if let set = PortalConfig.load().picturesControl, !set.isEmpty { candidates.append(NSString(string: set).expandingTildeInPath) }
    if let root = ProcessInfo.processInfo.environment["LOCALGEN_HOME"] { candidates.append(root + "/.run/daemon.sock") }
    candidates.append("\(home)/local-generators/.run/daemon.sock")
    return candidates.first { FileManager.default.fileExists(atPath: $0) }
  }

  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    // A render sends nothing until it is finished, so the idle timeout has to cover the whole render.
    config.timeoutIntervalForRequest = 1830
    config.timeoutIntervalForResource = 1900
    return URLSession(configuration: config)
  }()

  /// One picture. `images` are reference pictures (file bytes) the prompt calls "image 1", "image 2"…
  public static func generate(prompt: String, engine: PictureEngine, width: Int, height: Int, alpha: Bool, images: [Data] = [], progress: (@Sendable (String) -> Void)? = nil) async throws -> CGImage {
    var body: [String: JSONValue] = [
      "prompt": .string(prompt), "model": .string(engine.serverModel), "width": .number(String(width)), "height": .number(String(height)),
      "alpha": .bool(alpha), "format": "png",
    ]
    if !images.isEmpty { body["images"] = .array(images.map { .string($0.base64EncodedString()) }) }
    var request = URLRequest(url: address.appendingPathComponent("generate-image"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(JSONValue.object(body).serialized().utf8)

    // While the render runs, read its progress from the control socket (when there is one).
    let watcher = Task.detached {
      var last = ""
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled, let now = status().progress, now != last else { continue }
        last = now
        progress?(now)
      }
    }
    defer { watcher.cancel() }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
      throw PortalError.image("The Qwen server at \(address.absoluteString) is not answering. Start it, set another address with /pictures server <url>, or go back to Apple's with /pictures apple.")
    }
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      let reason = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw PortalError.image("The Qwen server refused (\(code)): \(reason.isEmpty ? "no reason given" : reason)")
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      throw PortalError.image("The Qwen server answered with something that is not a picture.")
    }
    return image
  }

  /// Is anything listening at the server address?
  public static func reachable() async -> Bool {
    var request = URLRequest(url: address)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 2
    return (try? await URLSession.shared.data(for: request)) != nil
  }

  /// Loaded state from the control socket. Quick (local socket), safe to call from a timer.
  public static func status() -> QwenStatus {
    guard let reply = try? rpc("status") else { return QwenStatus(state: controlSocket == nil ? .unknown : .unreachable) }
    let engine = reply["engines"]?[engineName]
    let running = engine?["running"]?.boolValue ?? false
    let busy = engine?["busy"]?.boolValue ?? false
    var out = QwenStatus(state: busy ? .busy : running ? .loaded : .unloaded)
    out.variant = engine?["loaded"]?["variant"]?.stringValue
    out.idleSeconds = engine?["idle_s"]?.intValue
    out.memoryGB = running ? Double(engine?["est_gb"]?.stringValue ?? "") : nil
    if let job = reply["jobs"]?.arrayValue?.first(where: { ($0["kind"]?.stringValue ?? "").contains("generate") && $0["status"]?.stringValue == "running" }) ?? reply["jobs"]?.arrayValue?.first {
      if job["status"]?.stringValue == "queued" {
        out.progress = "waiting for another job to finish"
      } else if let step = job["progress"]?["step"]?.intValue, let total = job["progress"]?["total"]?.intValue, total > 0, step > 0 {
        out.progress = "step \(step) of \(total)"
      } else if let stage = job["progress"]?["stage"]?.stringValue {
        out.progress = stage == "loading" ? "loading the model" : stage
      }
      if out.state != .busy, job["status"]?.stringValue != nil { out.state = .busy }
    }
    return out
  }

  /// Frees the model's memory. Returns false if it was busy, not loaded, or there is no control socket.
  @discardableResult
  public static func unload() -> Bool {
    guard let reply = try? rpc("unload", ["engines": [.string(engineName)]]) else { return false }
    return reply["unloaded"]?.arrayValue?.contains(.string(engineName)) ?? false
  }

  /// One JSON-RPC call to the daemon: HTTP/1.0 over its unix socket.
  private static func rpc(_ method: String, _ params: JSONValue = [:]) throws -> JSONValue {
    guard let path = controlSocket else { throw PortalError.image("No localgen control socket found.") }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw PortalError.image("socket() failed") }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 4, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { throw PortalError.image("The control socket path is too long.") }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      for (i, b) in bytes.enumerated() { raw[i] = b }
    }
    let connected = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw PortalError.image("The localgen daemon is not answering on its socket.") }

    let body = JSONValue.object(["method": .string(method), "params": params]).serialized()
    let head = "POST /rpc HTTP/1.0\r\nHost: localgen\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
    var out = Array((head + body).utf8)
    while !out.isEmpty {
      let sent = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      guard sent > 0 else { throw PortalError.image("Couldn't write to the localgen socket.") }
      out.removeFirst(sent)
    }
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 16384)
    while true {
      let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if n <= 0 { break }
      received.append(contentsOf: buffer[0..<n])
    }
    guard let split = received.range(of: Data("\r\n\r\n".utf8)) else { throw PortalError.image("The localgen daemon sent an unreadable reply.") }
    let json = try JSONValue.parse(received[split.upperBound...])
    guard json["ok"]?.boolValue == true, let result = json["result"] else { throw PortalError.image(json["error"]?.stringValue ?? "The localgen daemon reported an error.") }
    return result
  }
}

/// Drawing, editing and filling, whichever engine is selected.
public enum Pictures {
  /// Longest side sent to and asked back from the Qwen server.
  static let maxSide = 1280

  static func styleText(_ style: String) -> String {
    switch style {
    case "animation": return "3D animated film style with soft lighting."
    case "sketch": return "Hand-drawn pencil sketch on plain paper."
    default: return "Storybook illustration with clean shapes and soft flat colours."
    }
  }

  /// New pictures from words. Stickers come back transparent and trimmed.
  public static func draw(_ request: PictureRequest, engine: PictureEngine = .current, progress: (@Sendable (String) -> Void)? = nil) async throws -> [CGImage] {
    guard engine.canEdit else {
      return try await ImagePipeline.generate(prompt: request.prompt, style: request.style, count: request.count)
    }
    let sticker = request.purpose == .sticker
    let size = request.size ?? (sticker ? (768, 768) : (1216, 832))
    let prompt = sticker
      ? "\(request.prompt). A single subject, centred, whole and fully inside the frame, no text. \(styleText(request.style))"
      : "\(request.prompt). A wide scene with no text or lettering. \(styleText(request.style))"
    var images: [CGImage] = []
    let count = max(1, min(request.count, 4))
    for n in 1...count {
      try Task.checkCancellation()
      if count > 1 { progress?("picture \(n) of \(count)") }
      do {
        let image: CGImage
        if engine == .openrouter {
          progress?(count > 1 ? "picture \(n) of \(count) · waiting for \(OpenRouter.imageModel)" : "waiting for \(OpenRouter.imageModel) on OpenRouter")
          image = try await OpenRouter.image(prompt: prompt, ratio: Double(size.0) / Double(size.1), transparent: sticker)
        } else {
          image = try await QwenServer.generate(prompt: prompt, engine: engine, width: size.0, height: size.1, alpha: sticker, progress: { text in
            progress?(count > 1 ? "picture \(n) of \(count) · \(text)" : text)
          })
        }
        images.append(sticker ? try transparentSticker(image) : image)
      } catch {
        // Keep what already arrived when a later picture of a batch fails.
        if images.isEmpty { throw error }
        break
      }
    }
    return images
  }

  /// Most hosted models cannot draw transparency, so an opaque sticker gets the same Vision cut-out as /cutout.
  static func transparentSticker(_ image: CGImage) throws -> CGImage {
    ImagePipeline.trimTransparent(ImagePipeline.hasTransparency(image) ? image : try ImagePipeline.cutout(image))
  }

  private static func requireEditing(_ engine: PictureEngine, _ what: String) throws {
    guard engine.canEdit else {
      throw PortalError.image("\(what) needs the Qwen or OpenRouter picture engine; Apple's Image Playground only draws new pictures. Turn one on with /pictures qwen-turbo (needs a localgen server) or /pictures openrouter (needs a key).")
    }
  }

  /// One repaint by whichever engine: `reference` is PNG bytes of a `w`×`h` picture; the answer comes back at that size.
  private static func repaint(_ prompt: String, reference: Data, w: Int, h: Int, alpha: Bool, engine: PictureEngine, progress: (@Sendable (String) -> Void)?) async throws -> CGImage {
    guard engine == .openrouter else {
      return try await QwenServer.generate(prompt: prompt, engine: engine, width: w, height: h, alpha: alpha, images: [reference], progress: progress)
    }
    progress?("waiting for \(OpenRouter.imageModel) on OpenRouter")
    let answer = try await OpenRouter.image(prompt: prompt, ratio: Double(w) / Double(h), transparent: alpha, references: [reference])
    // The model picks its own size from a few aspect ratios; bring it back to the picture's.
    return try ImagePipeline.resized(answer, width: w, height: h)
  }

  /// A size with the picture's proportions whose longest side is at most `maxSide`.
  static func workingSize(_ image: CGImage) -> (Int, Int) {
    let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
    return (max(64, Int((Double(image.width) * scale).rounded())), max(64, Int((Double(image.height) * scale).rounded())))
  }

  /// Changes a whole picture as instructed ("make it night", "turn the roof red").
  public static func edit(_ image: CGImage, instruction: String, engine: PictureEngine = .current, progress: (@Sendable (String) -> Void)? = nil) async throws -> CGImage {
    try requireEditing(engine, "Editing")
    let alpha = ImagePipeline.hasTransparency(image)
    let (w, h) = workingSize(image)
    var source = try ImagePipeline.resized(image, width: w, height: h)
    // Hosted models do not read transparency: a sticker reaches them on black and comes back on a noisy dark
    // ground the cut-out cannot separate. Send it on white instead; the answer is cut out again below.
    let onWhite = alpha && engine == .openrouter
    if onWhite { source = try ImagePipeline.flattened(source) }
    let reference = try ImagePipeline.encode(source, purpose: .sticker).data
    let prompt = "Edit image 1: \(instruction). Keep the composition, the subject and the art style of image 1 unless the instruction says otherwise.\(onWhite ? " Keep the plain white background." : "")"
    let out = try await repaint(prompt, reference: reference, w: w, h: h, alpha: alpha, engine: engine, progress: progress)
    // A sticker stays a sticker even when the model answers on an opaque background.
    return alpha && !ImagePipeline.hasTransparency(out) ? try transparentSticker(out) : out
  }

  /// Paints `what` into one rectangle of the picture and leaves every pixel outside it untouched.
  /// The rectangle is marked in flat magenta for the model, and the answer is blended back
  /// through a soft-edged mask of the same rectangle.
  public static func fill(_ image: CGImage, area: FillArea, what: String, engine: PictureEngine = .current, progress: (@Sendable (String) -> Void)? = nil) async throws -> CGImage {
    try requireEditing(engine, "Filling")
    guard !ImagePipeline.hasTransparency(image) else {
      throw PortalError.image("Fill works on pictures without transparency. For a sticker, use /edit instead.")
    }
    let (w, h) = workingSize(image)
    let base = try ImagePipeline.resized(image, width: w, height: h)
    // Top-left fractions to CoreGraphics' bottom-left pixels.
    let rect = CGRect(x: area.x * Double(w), y: (1 - area.y - area.height) * Double(h), width: area.width * Double(w), height: area.height * Double(h)).integral
    let marked = try ImagePipeline.painted(base, rect: rect, red: 1, green: 0, blue: 1)
    let reference = try ImagePipeline.encode(marked, purpose: .sticker).data
    let prompt = "Edit image 1: replace the solid magenta rectangle with \(what), painted to blend naturally into the surrounding scene in the same art style. No magenta remains. Everything outside that rectangle stays exactly as in image 1."
    let answer = try await repaint(prompt, reference: reference, w: w, h: h, alpha: false, engine: engine, progress: progress)
    return try ImagePipeline.blend(try ImagePipeline.resized(answer, width: w, height: h), over: base, inside: rect)
  }
}
