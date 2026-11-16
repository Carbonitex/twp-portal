import AppKit
import PortalCore
import SwiftUI
import WebKit

/// The live game, embedded: one web view on the TWP website that stays loaded
/// while the app runs. It keeps the website's own sign-in (a cookie in this
/// app's private web data, separate from Safari), so the link used by the chat
/// and the game's sign-in are two different things.
@MainActor
final class GameSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
  let webView: WKWebView
  @Published var loading = false
  @Published var canGoBack = false
  /// The scene the game is showing, read from its address.
  @Published var sceneId: String?
  /// Who the game is signed in as; nil while unknown, "" for a guest.
  @Published var player: String?
  @Published var problem: String?

  /// Called when the player walks to another scene inside the game.
  var onScene: ((String) -> Void)?

  private(set) var origin = PortalEnvironment.production.origin
  private var started = false
  private var observers: [NSKeyValueObservation] = []
  private var playerCheck: Task<Void, Never>?

  /// Called when the page reports who is playing ("" for a guest).
  var onPlayer: ((String) -> Void)?
  /// A guest view keeps nothing: no cookie, so it shows what a visitor sees.
  let guestOnly: Bool
  /// Where to go once a sign-in has landed.
  private var afterSignIn: String?
  private var signingIn = false

  init(guestOnly: Bool = false) {
    self.guestOnly = guestOnly
    let config = WKWebViewConfiguration()
    config.websiteDataStore = guestOnly ? .nonPersistent() : .default()
    config.mediaTypesRequiringUserActionForPlayback = []
    webView = WKWebView(frame: .zero, configuration: config)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    webView.underPageBackgroundColor = .black
    observers = [
      webView.observe(\.url) { [weak self] view, _ in
        let url = view.url
        Task { @MainActor in self?.addressChanged(url) }
      },
      webView.observe(\.isLoading) { [weak self] view, _ in
        let loading = view.isLoading
        Task { @MainActor in self?.loading = loading }
      },
      webView.observe(\.canGoBack) { [weak self] view, _ in
        let can = view.canGoBack
        Task { @MainActor in self?.canGoBack = can }
      },
    ]
  }

  /// Points the game at a server. Changing servers starts a fresh page there.
  func use(origin: URL) {
    guard origin != self.origin else { return }
    self.origin = origin
    webView.isInspectable = origin != PortalEnvironment.production.origin
    sceneId = nil
    player = nil
    if started {
      started = false
      webView.load(URLRequest(url: URL(string: "about:blank")!))
    }
  }

  static func isSceneId(_ text: String) -> Bool { (15...20).contains(text.count) && text.allSatisfy(\.isNumber) }

  private var onSite: Bool { webView.url?.host == origin.host }

  /// Shows a scene (or the game's own starting place when nil). Walks there
  /// inside the running page when it can, so music and state carry on.
  func show(_ scene: String?) {
    problem = nil
    guard started, onSite else {
      started = true
      webView.load(URLRequest(url: scene.map { origin.appendingPathComponent($0) } ?? origin))
      return
    }
    guard let scene, scene != sceneId, Self.isSceneId(scene) else { return }
    // The site listens for popstate and switches scene from the new address.
    let script = "history.pushState('\(scene)', '\(scene)', '/\(scene)'); window.dispatchEvent(new PopStateEvent('popstate', { state: '\(scene)' }));"
    webView.evaluateJavaScript(script) { [weak self] _, error in
      guard error != nil, let self else { return }
      self.webView.load(URLRequest(url: self.origin.appendingPathComponent(scene)))
    }
  }

  /// Loads a one-time sign-in address, then goes to `scene`. The address is never kept or shown.
  func signIn(with url: URL, then scene: String?) {
    guard !guestOnly else { return }
    started = true
    signingIn = true
    afterSignIn = scene ?? sceneId
    player = nil
    webView.load(URLRequest(url: url))
  }

  /// Signs the game out of the website and forgets its cookies for this server.
  func signOut() {
    guard !guestOnly else { return }
    player = nil
    let host = origin.host ?? ""
    let store = webView.configuration.websiteDataStore.httpCookieStore
    let finish: () -> Void = { [weak self] in
      store.getAllCookies { cookies in
        for cookie in cookies where cookie.domain.hasSuffix(host) { store.delete(cookie) }
        Task { @MainActor in self?.reload() }
      }
    }
    guard started, onSite else { return finish() }
    webView.callAsyncJavaScript("await fetch('/api/auth/logout', { method: 'POST', credentials: 'same-origin' }); return true;", arguments: [:], in: nil, in: .page) { _ in finish() }
  }

  /// Loads the page again, so changes made from the chat show up.
  func reload() {
    guard started else { return }
    problem = nil
    if onSite { webView.reload() } else { webView.load(URLRequest(url: sceneId.map { origin.appendingPathComponent($0) } ?? origin)) }
  }

  func goBack() { webView.goBack() }

  var address: URL? { onSite ? webView.url : nil }

  private func addressChanged(_ url: URL?) {
    guard let url, url.host == origin.host else { return }
    let first = url.path.split(separator: "/").first.map(String.init) ?? ""
    guard Self.isSceneId(first), first != sceneId else { return }
    sceneId = first
    // The landing scene right after a sign-in is not somewhere the player chose to go.
    if !signingIn { onScene?(first) }
  }

  /// Asks the page who is playing. The page fills this in a moment after it loads, so try a few times.
  private func checkPlayer() {
    playerCheck?.cancel()
    playerCheck = Task { [weak self] in
      for _ in 0..<8 {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard let self, !Task.isCancelled, self.onSite else { return }
        let script = "(function(){var a=window.twpApp&&window.twpApp.twpAccount;if(!a||!a.accountId)return '';return JSON.stringify({guest:!!a.is_guest||a.accountId==='guest',name:a.displayName||''});})()"
        guard let text = try? await self.webView.evaluateJavaScript(script) as? String, !text.isEmpty,
              let json = try? JSONValue.parse(text)
        else { continue }
        let guest = json["guest"]?.boolValue ?? true
        let name = guest ? "" : (json["name"]?.stringValue ?? "player")
        self.player = name
        self.onPlayer?(name)
        return
      }
    }
  }

  // MARK: WKNavigationDelegate

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.allow) }
    if ["http", "https", "about", "blob", "data"].contains(scheme) { return decisionHandler(.allow) }
    // mailto:, discord: and the like belong to other apps.
    NSWorkspace.shared.open(url)
    decisionHandler(.cancel)
  }

  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    decisionHandler(response.canShowMIMEType ? .allow : .download)
  }

  func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
  func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    problem = nil
    let path = webView.url?.path ?? ""
    // A sign-in passes through the claim address and a "signed in" page before the game itself.
    if signingIn, onSite, !path.hasPrefix("/api/"), !path.hasPrefix("/login-success") {
      signingIn = false
      if let scene = afterSignIn { show(scene) }
      afterSignIn = nil
    }
    addressChanged(webView.url)
    if onSite, !signingIn { checkPlayer() }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

  private func failed(_ error: Error) {
    let ns = error as NSError
    // Cancelled loads and "became a download" are not failures.
    if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
    if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }
    signingIn = false
    problem = error.localizedDescription
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reload() }

  // MARK: WKUIDelegate

  /// Links that ask for a new window: the site's own pages stay here, anything else opens in the browser.
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard let url = action.request.url else { return nil }
    if url.host == origin.host { webView.load(action.request) } else { NSWorkspace.shared.open(url) }
    return nil
  }

  func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
  }

  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    let alert = NSAlert()
    alert.messageText = message
    alert.runModal()
    completionHandler()
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    let alert = NSAlert()
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    completionHandler(alert.runModal() == .alertFirstButtonReturn)
  }

  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
    let alert = NSAlert()
    alert.messageText = prompt
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = defaultText ?? ""
    alert.accessoryView = field
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
  }

  // MARK: WKDownloadDelegate

  /// Files the game offers (a saved picture, an item's attachment) land in Downloads, never over an existing file.
  func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
    let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    let name = (suggestedFilename as NSString).lastPathComponent
    let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
    var target = folder.appendingPathComponent(name.isEmpty ? "download" : name)
    var n = 2
    while FileManager.default.fileExists(atPath: target.path) {
      target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
      n += 1
    }
    completionHandler(target)
  }
}

struct GameWeb: NSViewRepresentable {
  let session: GameSession
  func makeNSView(context: Context) -> WKWebView { session.webView }
  func updateNSView(_ view: WKWebView, context: Context) {}
}

/// The game with a slim bar above it: back, reload, who is playing.
struct GamePane: View {
  @EnvironmentObject var model: PortalModel
  @ObservedObject var game: GameSession

  private var playerLine: String? {
    if game.guestOnly { return "Viewing as a guest: what a visitor sees" }
    guard let player = game.player else { return nil }
    if player.isEmpty { return model.gameNeedsLink ? "Playing as a guest" : "Playing as a guest · sign in inside the game" }
    return "Playing as \(player)"
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Button { game.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!game.canGoBack).help("Back")
        Button { game.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload the game")
        if game.loading { ProgressView().controlSize(.small) }
        if let line = playerLine {
          Text(line).font(.caption).foregroundStyle(game.guestOnly || game.player?.isEmpty == true ? Palette.user : Palette.dim).lineLimit(1)
        }
        if !game.guestOnly, game.player?.isEmpty == true, model.gameNeedsLink {
          Button("Link Again to Sign In…") { model.run("/login") }.buttonStyle(.link).font(.caption).disabled(model.busy)
            .help("This Mac was linked before the game could sign in. Linking again adds that permission.")
        }
        Spacer()
        Button { model.setGuestView(!model.guestView) } label: {
          Image(systemName: model.guestView ? "person.crop.circle.badge.questionmark.fill" : "person.crop.circle.badge.questionmark")
            .foregroundStyle(model.guestView ? Palette.user : Palette.text)
        }
        .help(model.guestView ? "Back to playing as you" : "See this scene as a guest would")
        Button { model.openGameInBrowser() } label: { Image(systemName: "safari") }.help("Open this in your browser")
        Button { model.chatHidden.toggle() } label: { Image(systemName: "sidebar.right") }
          .help(model.chatHidden ? "Show the chat" : "Hide the chat")
      }
      .buttonStyle(.plain)
      .foregroundStyle(Palette.text)
      .padding(.horizontal, 12).padding(.vertical, 7)
      .background(Palette.panel)

      ZStack {
        // Two different web views share this spot; the id makes SwiftUI swap them.
        GameWeb(session: game).id(game.guestOnly)
        if let problem = game.problem {
          VStack(spacing: 10) {
            Text("The game could not load").font(.headline)
            Text(problem).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try Again") { game.reload() }
          }
          .padding(24)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Palette.background)
        }
      }
    }
  }
}
