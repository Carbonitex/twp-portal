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
  /// True while /login is waiting on the browser, so the UI can offer "open again" and "cancel".
  @Published var linking = false
  @Published var signedIn = false
  @Published var account: Account?
  @Published var scenes: [SceneSummary] = []
  @Published var sceneFilter = ""
  @Published var folders: [SceneFolder] = []
  /// Folders opened in the sidebar. Remembered between launches.
  @Published var openFolders: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "openFolders") ?? []) {
    didSet { UserDefaults.standard.set(Array(openFolders), forKey: "openFolders") }
  }
  @Published var focus: SceneSummary?
  @Published var preview: NSImage?
  @Published var previewLoading = false
  @Published var previewError: String?
  @Published var brain: Brain = .onDevice
  /// The local model server's state, refreshed at launch and after /brain commands.
  @Published var localBrain = LocalBrain.lastStatus
  /// An OpenRouter key is stored (or in the environment): the OpenRouter menu entries are enabled.
  @Published var openrouterReady = OpenRouter.hasKey
  @Published var dropTargeted = false
  @Published var sidebarTab: SidebarTab = .scenes
  /// The lightbulb: show the suggestion library even mid-conversation.
  @Published var startersRequested = false
  /// The user's most recent scene with something in it, so suggestions name something real.
  @Published var starterScene: SceneSummary?
  @Published var shelf: [ShelfItem] = []
  @Published var selectedLocal: ShelfItem?
  // Picture engine (Apple's Image Playground, or an optional local Qwen server).
  @Published var pictureEngine: PictureEngine = .current
  /// The OpenRouter picture model, for the check mark in the pictures menu.
  @Published var openrouterImageModel = OpenRouter.imageModel
  /// Loaded state of the Qwen model, polled while a Qwen engine is selected.
  @Published var qwenStatus: QwenStatus?
  @Published var autoOffMinutes: Int? = PortalConfig.load().picturesAutoOff
  /// "step 3 of 8" while a picture renders.
  @Published var progressText: String?
  /// The live game beside the chat (the website, embedded). Remembered between launches.
  @Published var gameShown = UserDefaults.standard.bool(forKey: "gameShown") {
    didSet { UserDefaults.standard.set(gameShown, forKey: "gameShown") }
  }
  /// Give the game the whole window.
  @Published var chatHidden = false
  let game = GameSession()
  /// A second, cookie-less copy of the game: the scene as a visitor sees it.
  let guestGame = GameSession(guestOnly: true)
  @Published var guestView = false
  /// The link lacks the game permission, so the game cannot sign in until this Mac is linked again.
  @Published var gameNeedsLink = false
  private var gameSignInTried = false
  var activeGame: GameSession { guestView ? guestGame : game }
  /// A request changed something, so the game should load the scene again.
  private var gameStale = false
  private var statusTimer: Timer?
  private var runTask: Task<Void, Never>?
  /// Bumped to send keyboard focus back to the input.
  @Published var focusTick = 0

  // The Fill sheet: drag a box on the picture, say what goes there.
  @Published var fillItem: ShelfItem?
  @Published var fillImage: NSImage?
  /// The dragged box in fractions of the picture, from its top-left corner.
  @Published var fillBox: CGRect = .zero
  @Published var fillText = ""

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
    statusTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.pollPictures() }
    }
    pollPictures()
    game.onScene = { [weak self] id in Task { await self?.focusChanged(to: id, fromGame: true) } }
    guestGame.onScene = { [weak self] id in Task { await self?.focusChanged(to: id, fromGame: true) } }
    game.onPlayer = { [weak self] name in if name.isEmpty { Task { await self?.signGameIn() } } }
  }

  /// The game came up as a guest while this Mac is linked: sign it in as the same account, once.
  private func signGameIn() async {
    guard signedIn, !gameSignInTried else { return }
    gameSignInTried = true
    switch await portal.auth.gameSignIn() {
    case .url(let url):
      gameNeedsLink = false
      game.signIn(with: url, then: focus?.id)
    case .needsPermission: gameNeedsLink = true
    case .notLinked: break
    case .unavailable(let why): receive(.info("The game could not be signed in for you (\(why)). You can still sign in inside it."))
    }
  }

  func setGuestView(_ guest: Bool) {
    guard guest != guestView else { return }
    let scene = activeGame.sceneId ?? focus?.id
    guestView = guest
    activeGame.show(scene)
  }

  // MARK: Game

  func setGame(_ shown: Bool) {
    chatHidden = false
    guard shown != gameShown else { return }
    gameShown = shown
    if shown { activeGame.show(focus?.id) } else if focus != nil, preview == nil { Task { await refreshPreview() } }
  }

  func openGameInBrowser() {
    NSWorkspace.shared.open(activeGame.address ?? focus.map { environment.origin.appendingPathComponent($0.id) } ?? environment.origin)
  }

  /// `/game`, `/game on|off|reload`, `/game <scene id>`: handled here because the game lives in the window.
  private func gameCommand(_ argument: String) {
    switch argument {
    case "": setGame(!gameShown)
    case "guest":
      setGame(true)
      setGuestView(true)
    case "me":
      setGame(true)
      setGuestView(false)
    case "on", "show": setGame(true)
    case "off", "hide": setGame(false)
    case "reload":
      setGame(true)
      activeGame.reload()
    default:
      guard GameSession.isSceneId(argument) else {
        receive(.error("Usage: /game [on|off|reload|guest|me|<scene id>]"))
        return
      }
      setGame(true)
      activeGame.show(argument)
    }
    receive(.info(!gameShown ? "The game is hidden." : guestView ? "Showing the game as a guest: what a visitor sees." : "The game is showing beside the chat. Walking to a scene makes it “this scene” here."))
  }

  // MARK: Picture engine

  private var polling = false
  private var pollCount = 0
  private var serverUp = true

  /// Reads the Qwen model's state for the status light and applies the auto-off setting.
  /// The control socket is local and answers in milliseconds; the HTTP reachability check runs less often.
  func pollPictures() {
    guard pictureEngine.isQwen else {
      qwenStatus = nil
      return
    }
    guard !polling else { return }
    polling = true
    pollCount += 1
    let checkServer = pollCount % 4 == 1
    let autoOff = autoOffMinutes
    Task.detached { [weak self] in
      var status = QwenServer.status()
      let up = checkServer ? await QwenServer.reachable() : nil
      if let minutes = autoOff, status.state == .loaded, let idle = status.idleSeconds, idle >= minutes * 60, QwenServer.unload() {
        status = QwenStatus(state: .unloaded)
      }
      let final = status
      await MainActor.run {
        guard let self else { return }
        if let up { self.serverUp = up }
        var shown = final
        if !self.serverUp, shown.state == .unknown || shown.state == .unloaded { shown.state = .unreachable }
        if self.qwenStatus != shown { self.qwenStatus = shown }
        self.polling = false
      }
    }
  }

  func setPictureEngine(_ engine: PictureEngine) {
    guard !busy else { return }
    run("/pictures \(engine.rawValue)")
  }

  func unloadQwen() {
    Task.detached { [weak self] in
      let done = QwenServer.unload()
      await MainActor.run {
        self?.receive(.info(done ? "Unloaded the Qwen model; its memory is free. It loads again on the next picture." : "Nothing was unloaded (the model is not loaded, or is busy)."))
        self?.pollPictures()
      }
    }
  }

  func setAutoOff(_ minutes: Int?) {
    autoOffMinutes = minutes
    var config = PortalConfig.load()
    config.picturesAutoOff = minutes
    config.save()
  }

  private func syncPictureSettings() {
    pictureEngine = .current
    openrouterImageModel = OpenRouter.imageModel
    autoOffMinutes = PortalConfig.load().picturesAutoOff
    pollCount = 0
    pollPictures()
  }

  /// Stops a picture that is being drawn (closing the request cancels the render on the server).
  func stop() { runTask?.cancel() }

  // MARK: Fill sheet

  func beginFill(_ item: ShelfItem) {
    fillImage = NSImage(contentsOf: item.url)
    fillBox = .zero
    fillText = ""
    fillItem = item
  }

  var fillReady: Bool { fillBox.width >= 0.03 && fillBox.height >= 0.03 && !fillText.trimmingCharacters(in: .whitespaces).isEmpty }

  func commitFill() {
    guard let item = fillItem, fillReady else { return }
    let area = FillArea(x: fillBox.minX, y: fillBox.minY, width: fillBox.width, height: fillBox.height)
    let what = fillText.trimmingCharacters(in: .whitespaces)
    fillItem = nil
    run("/fill \(item.name) \(area.text) \(what)")
  }

  func beginEdit(_ item: ShelfItem) {
    input = "/edit \(item.name) "
    focusTick += 1
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
    portal.agent.imageGenerator = { [weak self] request in
      // The optional Qwen and OpenRouter engines draw by themselves; progress lands in the "Working…" row.
      if PictureEngine.current.canEdit {
        return try await Pictures.draw(request, progress: { text in DispatchQueue.main.async { self?.receive(.progress(text)) } })
      }
      do {
        return try await ImagePipeline.generate(prompt: request.prompt, style: request.style, count: request.count)
      } catch PortalError.image {
        // Apple's programmatic generator is unavailable: let the user make the
        // picture in Image Playground, seeded with the same prompt.
        guard let self, let url = await self.runPlayground(request.prompt, style: request.style) else { throw PortalError.image("No picture was created.") }
        return [try ImagePipeline.load(url)]
      }
    }
    self.portal = portal
    brain = portal.agent.brain
    entries = [Entry(kind: .info, text: "TWP Portal · \(environment.displayName) (\(environment.origin.host ?? "")). Type what you want, or /help.")]
    account = nil
    scenes = []
    folders = []
    focus = nil
    preview = nil
    game.use(origin: environment.origin)
    guestGame.use(origin: environment.origin)
    gameSignInTried = false
    gameNeedsLink = false
    if gameShown { activeGame.show(nil) }
    Task {
      localBrain = await LocalBrain.check()
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
      // "sleep 5" pauses the script (lets the game finish loading between steps).
      if line.hasPrefix("sleep "), let seconds = Double(line.dropFirst(6)) {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        continue
      }
      run(line)
      while busy { try? await Task.sleep(nanoseconds: 200_000_000) }
    }
  }

  func switchEnvironment(_ env: PortalEnvironment) {
    guard env != environment, !busy else { return }
    environment = env
    var config = PortalConfig.load()
    config.environment = env.configKey
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
      // Folders are a nicety: if the scene map cannot be read, the list simply shows flat.
      folders = (try? await portal.folders()) ?? folders
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

  // MARK: Folders

  /// Folders whose parent is `parent` (nil = top level), by name. A folder whose parent is unknown shows at the top.
  func childFolders(of parent: String?) -> [SceneFolder] {
    let known = Set(folders.map(\.id))
    return folders.filter { folder in
      let effective = folder.parentId.flatMap { known.contains($0) ? $0 : nil }
      return effective == parent
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Scenes filed directly in `folder` (nil = top level, including scenes whose folder is unknown).
  func scenes(in folder: String?) -> [SceneSummary] {
    let known = Set(folders.map(\.id))
    return scenes.filter { scene in scene.folderId.flatMap { known.contains($0) ? $0 : nil } == folder }
  }

  /// Every scene inside a folder, subfolders included.
  func sceneCount(inside folder: String) -> Int {
    scenes(in: folder).count + childFolders(of: folder).reduce(0) { $0 + sceneCount(inside: $1.id) }
  }

  func folderName(_ id: String?) -> String? { id.flatMap { id in folders.first { $0.id == id }?.name } }

  /// Opens every folder on the way to a scene, so a scene the agent just worked on is visible.
  private func reveal(_ scene: SceneSummary) {
    var next = scene.folderId
    var hops = 0
    while let id = next, hops < 32 {
      openFolders.insert(id)
      next = folders.first { $0.id == id }?.parentId
      hops += 1
    }
  }

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
    // A key typed into the input is never shown in the transcript or kept in the input history.
    let secret = line.lowercased().hasPrefix("/openrouter key ") && !line.lowercased().hasSuffix(" clear")
    if !secret { history.append(line) }
    historyIndex = nil
    entries.append(Entry(kind: .user, text: secret ? "/openrouter key ••••••••" : line))
    startersRequested = false
    let words = line.split(separator: " ").map(String.init)
    if words.first == "/game" {
      gameCommand(words.dropFirst().joined(separator: " "))
      return
    }
    busy = true
    gameStale = false
    linking = line.trimmingCharacters(in: .whitespaces) == "/login"
    // Commands that put a picture on the shelf bring the shelf into view.
    if ["/imagine", "/cutout", "/import", "/local", "/edit", "/fill"].contains(line.split(separator: " ").first.map(String.init) ?? "") { sidebarTab = .local }
    progressText = nil
    runTask = Task {
      await portal.handle(line)
      linking = false
      progressText = nil
      if line.hasPrefix("/brain") || line.hasPrefix("/openrouter") {
        brain = portal.agent.brain
        localBrain = LocalBrain.lastStatus
        openrouterReady = OpenRouter.hasKey
      }
      if line.hasPrefix("/pictures") { syncPictureSettings() } else if pictureEngine.isQwen { pollPictures() }
      // Let queued events land before the prompt comes back.
      await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
      busy = false
      let word = line.split(separator: " ").first.map(String.init) ?? ""
      // Unlinking signs the game out too; linking (again) lets it sign in as the linked account.
      if word == "/logout" { game.signOut() }
      if word == "/login" {
        gameSignInTried = false
        gameNeedsLink = false
      }
      if ["/login", "/logout"].contains(word) || !line.hasPrefix("/") || ["/call", "/whoami"].contains(word) { await refreshAccount() }
      if word == "/login", gameShown, game.player == "" { await signGameIn() }
      if !line.hasPrefix("/") || word == "/call", focus != nil {
        // The game is the preview while it shows; load it again only when something was changed.
        if gameShown { if gameStale { activeGame.reload() } } else { await refreshPreview() }
      }
    }
  }

  func cancelLinking() { Task { await portal.auth.cancelSignIn() } }
  func reopenLinkPage() { Task { await portal.auth.reopenSignInPage() } }

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
    case .toolCall(let name, let args):
      if !(name.hasPrefix("get_") || name.hasPrefix("list_") || name.hasPrefix("render_") || name.hasPrefix("view_") || ["whoami", "api_catalog"].contains(name)) { gameStale = true }
      entries.append(Entry(kind: .toolCall, text: "\(name) \(args == "{}" ? "" : args)"))
    case .toolResult(let name, let text, let isError):
      let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      entries.append(Entry(kind: isError ? .toolError : .toolResult, text: "\(name): \(flat.prefix(220))\(flat.count > 220 ? "…" : "")"))
    case .json(let t): entries.append(Entry(kind: .json, text: t))
    case .image(let data, let caption): entries.append(Entry(kind: .image, text: caption, image: NSImage(data: data)))
    case .progress(let t):
      if busy { progressText = t }
      return
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
    if gameShown { activeGame.show(scene.id) } else { Task { await refreshPreview() } }
  }

  /// The agent moved on to a scene, or (fromGame) the player walked to one in the game.
  private func focusChanged(to id: String, fromGame: Bool = false) async {
    if gameShown, !fromGame { activeGame.show(id) }
    if focus?.id == id { return }
    defer { if !gameShown { Task { await refreshPreview() } } }
    if !scenes.contains(where: { $0.id == id }) { scenes = (try? await portal.scenes()) ?? scenes }
    if let scene = scenes.first(where: { $0.id == id }) {
      reveal(scene)
      focus = scene
      portal.agent.focusScene = (scene.id, scene.name)
      preview = nil
    } else if let scene = try? await portal.sceneSummary(id: id) {
      // Someone else's scene that this account may view: not in the list, but it still gets the preview panel.
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
