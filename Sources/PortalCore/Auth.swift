import AppKit
import CryptoKit
import Foundation
import Network
import Security

// MARK: - Environments

/// Which thinkwith.pictures deployment the portal talks to. Each has its own
/// accounts, database and OAuth clients, so sign-in is per environment.
public struct PortalEnvironment: Hashable, Sendable, Codable {
  public var name: String
  public var origin: URL

  public init(name: String, origin: URL) {
    self.name = name
    self.origin = origin
  }

  public static let production = PortalEnvironment(name: "prod", origin: URL(string: "https://thinkwith.pictures")!)
  public static let builtIn: [PortalEnvironment] = [.production]
  /// What users get: production only, shown as "Online". A developer running
  /// their own server can point the portal at it with
  /// `twp --env <http(s) origin>` / `twp use <origin>`; it is never offered to users.
  public static let userFacing: [PortalEnvironment] = [.production]

  /// The name people see. Production is simply "Online".
  public var displayName: String {
    switch name {
    case "prod": return "Online"
    default: return name
    }
  }

  /// "prod", or any origin such as https://example.com or http://localhost:8798.
  public static func named(_ text: String) -> PortalEnvironment? {
    if let hit = builtIn.first(where: { $0.name == text.lowercased() }) { return hit }
    if text.lowercased() == "production" { return .production }
    guard let url = URL(string: text), let scheme = url.scheme, let host = url.host, ["http", "https"].contains(scheme) else { return nil }
    var c = URLComponents()
    c.scheme = scheme
    c.host = host
    c.port = url.port
    return c.url.map { PortalEnvironment(name: host, origin: $0) }
  }

  /// What is written to the config file so the choice survives a relaunch.
  public var configKey: String { self == .production ? "prod" : originString }

  public var mcpEndpoint: URL { origin.appendingPathComponent("api/twp/mcp") }
  var originString: String { origin.absoluteString.hasSuffix("/") ? String(origin.absoluteString.dropLast()) : origin.absoluteString }
}

// MARK: - Errors

public enum PortalError: LocalizedError {
  case notSignedIn
  case signInFailed(String)
  case signInCancelled
  case http(Int, String)
  case protocolError(String)
  case tool(String)
  case image(String)

  public var errorDescription: String? {
    switch self {
    case .notSignedIn: return "Not signed in. Run /login."
    case .signInFailed(let m): return "Sign-in failed: \(m)"
    case .signInCancelled: return "Linking cancelled. Nothing was linked."
    case .http(let code, let m): return "HTTP \(code): \(m)"
    case .protocolError(let m): return m
    case .tool(let m): return m
    case .image(let m): return m
    }
  }
}

// MARK: - Stored credentials

struct StoredGrant: Codable {
  var clientId: String
  var accessToken: String
  var refreshToken: String
  var expiresAt: Date
  var scope: String
}

/// Where the grant lives.
///
/// - A build signed with a real identity (Developer ID, has a Team ID) uses the
///   login Keychain: its "Always Allow" is tied to that stable identity.
/// - An ad-hoc or unsigned build (every local `scripts/build.sh`) has no stable
///   identity, so the Keychain treats each rebuild as a stranger and asks for
///   the login password again and again. Those builds use a 0600 file in
///   Application Support instead.
/// TWP_PORTAL_TOKEN_FILE=1 forces the file; =0 forces the Keychain.
///
/// The grant is cached in memory so the store is read once per launch, not
/// once per request; `fresh: true` re-reads (used before a token refresh, when
/// the CLI or the app may have rotated the token in the meantime).
enum GrantStore {
  static let service = "pictures.thinkwith.portal"

  static let useFile: Bool = {
    switch ProcessInfo.processInfo.environment["TWP_PORTAL_TOKEN_FILE"] {
    case "1": return true
    case "0": return false
    default: return !hasStableSigningIdentity
    }
  }()

  private static var hasStableSigningIdentity: Bool {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any]
    else { return false }
    return (dict[kSecCodeInfoTeamIdentifier as String] as? String)?.isEmpty == false
  }

  private static let cacheLock = NSLock()
  private static var cache: [String: StoredGrant?] = [:]

  static func load(_ env: PortalEnvironment, fresh: Bool = false) -> StoredGrant? {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    if !fresh, let hit = cache[env.originString] { return hit }
    var grant = read(env)
    if grant == nil, useFile { grant = migrateFromKeychain(env) }
    cache[env.originString] = .some(grant)
    return grant
  }

  private static func read(_ env: PortalEnvironment) -> StoredGrant? {
    guard let data = useFile ? try? Data(contentsOf: fileURL(env)) : keychainRead(env) else { return nil }
    return try? decoder.decode(StoredGrant.self, from: data)
  }

  /// A grant saved to the Keychain by an earlier build is moved to the file
  /// once (one last Keychain prompt at most), so the user is not asked to link again.
  private static func migrateFromKeychain(_ env: PortalEnvironment) -> StoredGrant? {
    let marker = PortalPaths.supportDirectory.appendingPathComponent(".keychain-migrated-\(fileURL(env).lastPathComponent)")
    guard !FileManager.default.fileExists(atPath: marker.path) else { return nil }
    FileManager.default.createFile(atPath: marker.path, contents: nil)
    guard let data = keychainRead(env), let grant = try? decoder.decode(StoredGrant.self, from: data) else { return nil }
    try? writeFile(data, env)
    SecItemDelete(baseQuery(env) as CFDictionary)
    return grant
  }

  static func save(_ grant: StoredGrant, _ env: PortalEnvironment) throws {
    let data = try encoder.encode(grant)
    if useFile { try writeFile(data, env) } else { try keychainWrite(data, env) }
    cacheLock.lock()
    cache[env.originString] = .some(grant)
    cacheLock.unlock()
  }

  private static func writeFile(_ data: Data, _ env: PortalEnvironment) throws {
    let url = fileURL(env)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  static func delete(_ env: PortalEnvironment) {
    if useFile { try? FileManager.default.removeItem(at: fileURL(env)) } else {
      SecItemDelete(baseQuery(env) as CFDictionary)
    }
    cacheLock.lock()
    cache[env.originString] = .some(nil)
    cacheLock.unlock()
  }

  private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
  private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

  private static func fileURL(_ env: PortalEnvironment) -> URL {
    let safe = env.originString.replacingOccurrences(of: "[^A-Za-z0-9.-]", with: "_", options: .regularExpression)
    return PortalPaths.supportDirectory.appendingPathComponent("grant-\(safe).json")
  }

  private static func baseQuery(_ env: PortalEnvironment) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: env.originString]
  }

  private static func keychainRead(_ env: PortalEnvironment) -> Data? {
    var q = baseQuery(env)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
  }

  private static func keychainWrite(_ data: Data, _ env: PortalEnvironment) throws {
    let status = SecItemUpdate(baseQuery(env) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    var add = baseQuery(env)
    add[kSecValueData as String] = data
    add[kSecAttrLabel as String] = "TWP Portal (\(env.name))"
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else {
      throw PortalError.signInFailed("could not save the sign-in to the Keychain (status \(added))")
    }
  }
}

public enum PortalPaths {
  public static var supportDirectory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("TWP Portal", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}

// MARK: - OAuth 2.1 (dynamic registration + PKCE + loopback redirect)

/// Signs the user in through the TWP website. The portal never sees a password:
/// it opens the site's own consent page in the default browser and receives a
/// one-time code on a loopback port (RFC 8252), then swaps it for tokens.
public actor PortalAuth {
  public static let defaultScopes = ["twp:profile", "twp:read", "twp:build", "twp:publish", "twp:play"]
  public let environment: PortalEnvironment
  private let session: URLSession
  private var refreshing: Task<StoredGrant, Error>?

  public init(environment: PortalEnvironment, session: URLSession = .shared) {
    self.environment = environment
    self.session = session
  }

  public var isSignedIn: Bool { GrantStore.load(environment) != nil }
  public var grantedScopes: [String] { (GrantStore.load(environment)?.scope ?? "").split(separator: " ").map(String.init) }

  /// A bearer token good for at least the next minute, refreshing if needed.
  public func accessToken(forceRefresh: Bool = false) async throws -> String {
    guard let grant = GrantStore.load(environment) else { throw PortalError.notSignedIn }
    if !forceRefresh, grant.expiresAt.timeIntervalSinceNow > 60 { return grant.accessToken }
    if let running = refreshing { return try await running.value.accessToken }
    let task = Task { try await self.refresh(staleAccessToken: grant.accessToken) }
    refreshing = task
    defer { refreshing = nil }
    return try await task.value.accessToken
  }

  /// Refresh tokens rotate on every use, and replaying a spent one revokes the
  /// whole grant. The CLI and the app share one grant, so the swap happens
  /// under a cross-process file lock, after re-reading what the other process
  /// may have just stored.
  private func refresh(staleAccessToken: String) async throws -> StoredGrant {
    let lockPath = PortalPaths.supportDirectory.appendingPathComponent("refresh.lock").path
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }

    guard let current = GrantStore.load(environment, fresh: true) else { throw PortalError.notSignedIn }
    if current.accessToken != staleAccessToken, current.expiresAt.timeIntervalSinceNow > 60 { return current }

    do {
      let json = try await postForm("api/oauth/token", [
        "grant_type": "refresh_token", "refresh_token": current.refreshToken, "client_id": current.clientId,
      ])
      let next = try grant(from: json, clientId: current.clientId, fallbackRefresh: current.refreshToken, fallbackScope: current.scope)
      try GrantStore.save(next, environment)
      return next
    } catch PortalError.http(let code, _) where code == 400 || code == 401 {
      GrantStore.delete(environment)
      throw PortalError.notSignedIn
    }
  }

  /// Full browser sign-in. `onURL` receives the consent URL (the CLI prints it
  /// in case the browser does not open).
  public func signIn(scopes: [String] = PortalAuth.defaultScopes, onURL: (@Sendable (URL) -> Void)? = nil) async throws {
    let clientId = try await registeredClientId()
    let verifier = Self.randomURLSafe(48)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    let state = Self.randomURLSafe(24)

    let listener = try LoopbackReceiver()
    let port = try await listener.start()
    let redirect = "http://127.0.0.1:\(port)/callback"

    var c = URLComponents(url: environment.origin.appendingPathComponent("api/oauth/authorize"), resolvingAgainstBaseURL: false)!
    c.queryItems = [
      .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientId),
      .init(name: "redirect_uri", value: redirect), .init(name: "scope", value: scopes.joined(separator: " ")),
      .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
      .init(name: "code_challenge_method", value: "S256"), .init(name: "resource", value: environment.mcpEndpoint.absoluteString),
    ]
    let url = c.url!
    onURL?(url)
    activeReceiver = listener
    pendingSignInURL = url
    defer {
      activeReceiver = nil
      pendingSignInURL = nil
    }
    await MainActor.run { _ = NSWorkspace.shared.open(url) }

    // Generous on purpose: a newcomer may be creating a Discord or Google
    // login, and their TWP account, before they ever reach Approve.
    let query = try await listener.waitForCallback(timeout: 900)
    if let err = query["error"] {
      throw PortalError.signInFailed(err == "access_denied" ? "you cancelled on the consent page" : (query["error_description"] ?? err))
    }
    guard query["state"] == state, let code = query["code"] else { throw PortalError.signInFailed("the browser returned an unexpected response") }

    let json = try await postForm("api/oauth/token", [
      "grant_type": "authorization_code", "code": code, "client_id": clientId, "redirect_uri": redirect, "code_verifier": verifier,
    ])
    try GrantStore.save(try grant(from: json, clientId: clientId, fallbackRefresh: "", fallbackScope: scopes.joined(separator: " ")), environment)
  }

  private var activeReceiver: LoopbackReceiver?
  /// The consent page of a sign-in that is waiting on the browser, if any.
  public private(set) var pendingSignInURL: URL?

  /// Stops waiting for the browser. The pending `signIn` throws `signInCancelled`.
  public func cancelSignIn() {
    activeReceiver?.cancel()
  }

  /// Opens the consent page again, for someone who closed the tab.
  public func reopenSignInPage() async {
    guard let url = pendingSignInURL else { return }
    await MainActor.run { _ = NSWorkspace.shared.open(url) }
  }

  public func signOut() async {
    if let grant = GrantStore.load(environment) {
      _ = try? await postForm("api/oauth/revoke", ["token": grant.refreshToken, "client_id": grant.clientId])
    }
    GrantStore.delete(environment)
  }

  // The client id is public (no secret) and reusable, so register once per
  // environment and remember it.
  private func registeredClientId() async throws -> String {
    let cache = PortalPaths.supportDirectory.appendingPathComponent("clients.json")
    var known = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: cache))) ?? [:]
    if let id = known[environment.originString] { return id }
    let body: JSONValue = [
      "client_name": "TWP Portal for Mac",
      "redirect_uris": ["http://127.0.0.1/callback"],
      "client_uri": .string(environment.originString),
      "software_id": "pictures.thinkwith.portal-mac",
      "grant_types": ["authorization_code", "refresh_token"],
      "token_endpoint_auth_method": "none",
    ]
    var req = URLRequest(url: environment.origin.appendingPathComponent("api/oauth/register"))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data(body.serialized().utf8)
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code), let id = try JSONValue.parse(data)["client_id"]?.stringValue else {
      throw PortalError.signInFailed("could not register with \(environment.originString) (HTTP \(code))")
    }
    known[environment.originString] = id
    try? JSONEncoder().encode(known).write(to: cache, options: [.atomic])
    return id
  }

  private func grant(from json: JSONValue, clientId: String, fallbackRefresh: String, fallbackScope: String) throws -> StoredGrant {
    guard let access = json["access_token"]?.stringValue else { throw PortalError.signInFailed("the server sent no access token") }
    return StoredGrant(
      clientId: clientId, accessToken: access, refreshToken: json["refresh_token"]?.stringValue ?? fallbackRefresh,
      expiresAt: Date().addingTimeInterval(TimeInterval(json["expires_in"]?.intValue ?? 3600)),
      scope: json["scope"]?.stringValue ?? fallbackScope)
  }

  private func postForm(_ path: String, _ fields: [String: String]) async throws -> JSONValue {
    var req = URLRequest(url: environment.origin.appendingPathComponent(path))
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    req.httpBody = Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    let json = (try? JSONValue.parse(data)) ?? .null
    guard (200..<300).contains(code) else {
      throw PortalError.http(code, json["error_description"]?.stringValue ?? json["error"]?.stringValue ?? "request failed")
    }
    return json
  }

  private static func randomURLSafe(_ bytes: Int) -> String {
    var buf = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
    return Data(buf).base64URLEncoded
  }
}

extension Data {
  var base64URLEncoded: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}

// MARK: - Loopback redirect receiver

/// A one-request HTTP listener on 127.0.0.1 that catches the OAuth redirect.
final class LoopbackReceiver: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "twp.portal.loopback")
  private var continuation: CheckedContinuation<[String: String], Error>?
  private var pending: Result<[String: String], Error>?

  init() throws {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    params.allowLocalEndpointReuse = true
    listener = try NWListener(using: params)
  }

  func start() async throws -> UInt16 {
    listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
      var resumed = false
      listener.stateUpdateHandler = { [listener] state in
        guard !resumed else { return }
        switch state {
        case .ready:
          resumed = true
          cont.resume(returning: listener.port?.rawValue ?? 0)
        case .failed(let err):
          resumed = true
          cont.resume(throwing: err)
        default: break
        }
      }
      listener.start(queue: queue)
    }
  }

  func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
    defer { listener.cancel() }
    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
      self?.finish(.failure(PortalError.signInFailed("no answer from the browser after 15 minutes. Choose Link Account to try again")))
    }
    return try await withCheckedThrowingContinuation { cont in
      queue.async {
        if let done = self.pending { cont.resume(with: done) } else { self.continuation = cont }
      }
    }
  }

  func cancel() {
    queue.async { self.finish(.failure(PortalError.signInCancelled)) }
  }

  private func finish(_ result: Result<[String: String], Error>) {
    if let cont = continuation {
      continuation = nil
      cont.resume(with: result)
    } else if pending == nil {
      pending = result
    }
  }

  private func handle(_ conn: NWConnection) {
    conn.start(queue: queue)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
      guard let self, let data, let head = String(data: data, encoding: .utf8)?.split(separator: "\r\n").first else { return conn.cancel() }
      let parts = head.split(separator: " ")
      let target = parts.count > 1 ? String(parts[1]) : "/"
      let comps = URLComponents(string: "http://127.0.0.1\(target)")
      guard comps?.path == "/callback" else {
        self.reply(conn, status: "404 Not Found", body: "Not found")
        return
      }
      var query: [String: String] = [:]
      for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
      let ok = query["code"] != nil
      self.reply(conn, status: "200 OK", body: Self.page(ok: ok))
      self.finish(.success(query))
    }
  }

  private func reply(_ conn: NWConnection, status: String, body: String) {
    let payload = Data(body.utf8)
    let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
  }

  private static func page(ok: Bool) -> String {
    let title = ok ? "You're signed in" : "Sign-in was cancelled"
    let line = ok ? "TWP Portal is now linked to your account. You can close this tab and return to the app." : "Nothing was linked. You can close this tab."
    return """
      <!doctype html><meta charset="utf-8"><title>TWP Portal</title>
      <body style="font:16px -apple-system,sans-serif;background:#14121a;color:#eee;display:grid;place-items:center;height:100vh;margin:0">
      <div style="text-align:center;max-width:26em"><h1 style="font-size:22px">\(title)</h1><p style="color:#aaa">\(line)</p></div></body>
      """
  }
}
