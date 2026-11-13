import AppKit
import ImagePlayground
import PortalCore
import SwiftUI

enum SidebarTab: Hashable { case scenes, local }

struct Entry: Identifiable {
  enum Kind { case user, assistant, info, error, toolCall, toolResult, toolError, json, image }
  let id = UUID()
  let kind: Kind
  var text: String
  var image: NSImage?
}

/// App state: one `Portal` per environment, the transcript, and the sidebar.
@MainActor
final class PortalModel: ObservableObject {
  @Published var environment: PortalEnvironment
  @Published var entries: [Entry] = []
  @Published var input = ""
  @Published var busy = false
  @Published var signedIn = false
  @Published var account: Account?
  @Published var scenes: [SceneSummary] = []
  @Published var sceneFilter = ""
  @Published var focus: SceneSummary?
  @Published var preview: NSImage?
  @Published var previewLoading = false
  @Published var previewError: String?
  @Published var brain: Brain = .onDevice
  @Published var dropTargeted = false
  @Published var sidebarTab: SidebarTab = .scenes
  /// The lightbulb: show the suggestion library even mid-conversation.
  @Published var startersRequested = false
  /// The user's most recent scene with something in it, so suggestions name something real.
  @Published var starterScene: SceneSummary?
  @Published var shelf: [ShelfItem] = []
  @Published var selectedLocal: ShelfItem?
  private var thumbnails: [String: NSImage] = [:]
  private var shelfObserver: NSObjectProtocol?

  // Confirmation of risky actions (publish, delete).
  @Published var confirmQuestion: String?
  private var confirmContinuation: CheckedContinuation<Bool, Never>?

  // Image Playground fallback for image generation.
  @Published var playgroundShown = false
  @Published var playgroundConcept = ""
  @Published var playgroundStyle: ImagePlaygroundStyle = .illustration
  private var playgroundContinuation: CheckedContinuation<URL?, Never>?

  private(set) var portal: Portal!
  private var history: [String] = []
  private var historyIndex: Int?

  init() {
    environment = PortalEnvironment.named(PortalConfig.load().environment) ?? .production
    connect()
    reloadShelf()
    shelfObserver = NotificationCenter.default.addObserver(forName: LocalShelf.didChange, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.reloadShelf() }
    }
  }

  // MARK: Local shelf

  func reloadShelf() {
    shelf = LocalShelf.list()
    if let selected = selectedLocal { selectedLocal = shelf.first { $0.id == selected.id } }
  }

  func isUploaded(_ item: ShelfItem) -> Bool {
    let origin = environment.origin.absoluteString
    return item.uploads.keys.contains { $0 == origin || $0 + "/" == origin || $0 == origin + "/" }
  }

  /// Small decoded previews, cached so the grid does not decode full images on every redraw.
  func thumbnail(for item: ShelfItem) -> NSImage? {
    let key = "\(item.id)|\(item.created.timeIntervalSince1970)"
    if let hit = thumbnails[key] { return hit }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true]
    guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    let made = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    thumbnails[key] = made
    return made
  }

  // MARK: Connection

  private func connect() {
    let portal = Portal(environment: environment) { [weak self] event in
      // The main queue is FIFO, so events keep the order they were emitted in.
      DispatchQueue.main.async { self?.receive(event) }
    }
    portal.agent.confirm = { [weak self] question in await self?.ask(question) ?? false }
    portal.agent.onFocusChange = { [weak self] id in
      DispatchQueue.main.async { Task { await self?.focusChanged(to: id) } }
    }
    portal.agent.imageGenerator = { [weak self] prompt, style, count in
      do {
        return try await ImagePipeline.generate(prompt: prompt, style: style, count: count)
      } catch PortalError.image {
        // Apple's programmatic generator is unavailable: let the user make the
        // picture in Image Playground, seeded with the same prompt.
        guard let self, let url = await self.runPlayground(prompt, style: style) else { throw PortalError.image("No picture was created.") }
        return [try ImagePipeline.load(url)]
      }
    }
    self.portal = portal
    brain = portal.agent.brain
    entries = [Entry(kind: .info, text: "TWP Portal · \(environment.displayName) (\(environment.origin.host ?? "")). Type what you want, or /help.")]
    account = nil
    scenes = []
    focus = nil
    preview = nil
    Task {
      await refreshAccount()
      await runStartupScript()
    }
  }

  /// TWP_PORTAL_RUN holds newline-separated lines to run at launch (demos and automated checks).
  private var startupScriptDone = false
  private func runStartupScript() async {
    // TWP_PORTAL_INPUT pre-fills the input (for checking the command helper).
    if !startupScriptDone, let typed = ProcessInfo.processInfo.environment["TWP_PORTAL_INPUT"] { input = typed }
    guard !startupScriptDone, let script = ProcessInfo.processInfo.environment["TWP_PORTAL_RUN"] else { return }
    startupScriptDone = true
    for line in script.split(separator: "\n").map(String.init) {
      run(line)
      while busy { try? await Task.sleep(nanoseconds: 200_000_000) }
    }
  }

  func switchEnvironment(_ env: PortalEnvironment) {
    guard env != environment, !busy else { return }
    environment = env
    var config = PortalConfig.load()
    config.environment = env.name
    config.save()
    connect()
  }

  func refreshAccount() async {
    signedIn = await portal.auth.isSignedIn
    guard signedIn else {
      account = nil
      scenes = []
      return
    }
    do {
      account = try await portal.account()
      scenes = try await portal.scenes()
      if starterScene == nil || !scenes.contains(where: { $0.id == starterScene?.id }) { starterScene = scenes.first { $0.objectCount > 0 } ?? scenes.first }
    } catch PortalError.notSignedIn {
      signedIn = false
    } catch {
      receive(.error(error.localizedDescription))
    }
  }

  /// Just Online for users (so no picker is shown); a developer who selected
  /// another server with `twp use` also gets that one, to switch back.
  var pickerEnvironments: [PortalEnvironment] {
    PortalEnvironment.userFacing.contains(environment) ? PortalEnvironment.userFacing : PortalEnvironment.userFacing + [environment]
  }

  /// Suggestions show while nothing has been asked yet, or when asked for with the lightbulb.
  var startersVisible: Bool { startersRequested || !entries.contains { $0.kind == .user } }

  var visibleScenes: [SceneSummary] {
    sceneFilter.isEmpty ? scenes : scenes.filter { $0.name.localizedCaseInsensitiveContains(sceneFilter) || $0.id.contains(sceneFilter) }
  }

  // MARK: Commands

  func submit() {
    let line = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty, !busy else { return }
    input = ""
    run(line)
  }

  func run(_ line: String) {
    guard !busy else { return }
    history.append(line)
    historyIndex = nil
    entries.append(Entry(kind: .user, text: line))
    startersRequested = false
    busy = true
    // Commands that put a picture on the shelf bring the shelf into view.
    if ["/imagine", "/cutout", "/import", "/local"].contains(line.split(separator: " ").first.map(String.init) ?? "") { sidebarTab = .local }
    Task {
      await portal.handle(line)
      // Let queued events land before the prompt comes back.
      await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
      busy = false
      let word = line.split(separator: " ").first.map(String.init) ?? ""
      if ["/login", "/logout"].contains(word) || !line.hasPrefix("/") || ["/call", "/whoami"].contains(word) { await refreshAccount() }
      if !line.hasPrefix("/") || word == "/call", focus != nil { await refreshPreview() }
    }
  }

  func recall(_ direction: Int) {
    guard !history.isEmpty else { return }
    let next = (historyIndex ?? history.count) + direction
    if next >= history.count {
      historyIndex = nil
      input = ""
    } else {
      historyIndex = max(0, next)
      input = history[historyIndex!]
    }
  }

  private func receive(_ event: PortalEvent) {
    switch event {
    case .info(let t): entries.append(Entry(kind: .info, text: t))
    case .error(let t): entries.append(Entry(kind: .error, text: t))
    case .assistant(let t): entries.append(Entry(kind: .assistant, text: t))
    case .toolCall(let name, let args): entries.append(Entry(kind: .toolCall, text: "\(name) \(args == "{}" ? "" : args)"))
    case .toolResult(let name, let text, let isError):
      let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      entries.append(Entry(kind: isError ? .toolError : .toolResult, text: "\(name): \(flat.prefix(220))\(flat.count > 220 ? "…" : "")"))
    case .json(let t): entries.append(Entry(kind: .json, text: t))
    case .image(let data, let caption): entries.append(Entry(kind: .image, text: caption, image: NSImage(data: data)))
    }
    if entries.count > 600 { entries.removeFirst(entries.count - 600) }
  }

  // MARK: Scenes and preview

  func select(_ scene: SceneSummary?) {
    focus = scene
    preview = nil
    previewError = nil
    guard let scene else {
      portal.agent.focusScene = nil
      return
    }
    portal.agent.focusScene = (scene.id, scene.name)
    Task { await refreshPreview() }
  }

  private func focusChanged(to id: String) async {
    if focus?.id == id { return }
    defer { Task { await refreshPreview() } }
    if !scenes.contains(where: { $0.id == id }) { scenes = (try? await portal.scenes()) ?? scenes }
    if let scene = scenes.first(where: { $0.id == id }) {
      focus = scene
      portal.agent.focusScene = (scene.id, scene.name)
      preview = nil
    }
  }

  func refreshPreview() async {
    guard let scene = focus, !previewLoading else { return }
    previewLoading = true
    previewError = nil
    defer { previewLoading = false }
    do {
      let data = try await portal.preview(sceneId: scene.id)
      if focus?.id == scene.id { preview = NSImage(data: data) }
    } catch {
      previewError = error.localizedDescription
    }
  }

  func openInBrowser(_ scene: SceneSummary) {
    NSWorkspace.shared.open(environment.origin.appendingPathComponent(scene.id))
  }

  // MARK: Confirmation and Image Playground

  private func ask(_ question: String) async -> Bool {
    await withCheckedContinuation { continuation in
      confirmContinuation?.resume(returning: false)
      confirmContinuation = continuation
      confirmQuestion = question
    }
  }

  func answer(_ yes: Bool) {
    confirmQuestion = nil
    confirmContinuation?.resume(returning: yes)
    confirmContinuation = nil
  }

  private func runPlayground(_ prompt: String, style: String) async -> URL? {
    await withCheckedContinuation { continuation in
      playgroundStyle = style == "animation" ? .animation : style == "sketch" ? .sketch : .illustration
      playgroundContinuation?.resume(returning: nil)
      playgroundContinuation = continuation
      playgroundConcept = prompt
      playgroundShown = true
    }
  }

  func playgroundFinished(_ url: URL?) {
    playgroundShown = false
    playgroundContinuation?.resume(returning: url)
    playgroundContinuation = nil
  }
}
