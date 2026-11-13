import CoreGraphics
import Foundation
import ImageIO

public struct ShelfItem: Identifiable, Sendable, Hashable {
  /// The file name, e.g. "red-windmill-2.png". Also what commands refer to.
  public let id: String
  public let url: URL
  public let prompt: String?
  public let created: Date
  public let hasAlpha: Bool
  public let width: Int
  public let height: Int
  /// assetKey per environment origin this file has been uploaded to.
  public let uploads: [String: String]

  public var name: String { id }
  /// Transparent pictures are stickers; opaque ones are backgrounds.
  public var suggestedPurpose: ImagePurpose { hasAlpha ? .sticker : .background }
}

/// The Local shelf: a plain folder on this Mac (`~/Pictures/TWP Portal`) where
/// generated and cut-out pictures wait until the user decides to upload one.
/// Nothing here touches the TWP account or spends strain. The folder is the
/// source of truth (files can be added or deleted in Finder); `shelf.json`
/// only remembers prompts and which files were uploaded where.
public enum LocalShelf {
  private struct Meta: Codable {
    var prompt: String?
    var uploads: [String: String] = [:]
  }

  /// Posted (on any thread) whenever the shelf's contents or upload marks change.
  public static let didChange = Notification.Name("TWPPortalLocalShelfDidChange")
  private static func changed() { NotificationCenter.default.post(name: didChange, object: nil) }

  /// The moment a picture leaves this Mac: uploads it to the TWP gallery and remembers the assetKey.
  public static func upload(_ item: ShelfItem, purpose: ImagePurpose, mcp: MCPClient, origin: String) async throws -> UploadedImage {
    let up = try await ImagePipeline.uploadFile(item.url, purpose: purpose, mcp: mcp)
    markUploaded(item, origin: origin, assetKey: up.assetKey)
    return up
  }

  private static let lock = NSLock()
  private static let extensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "tiff", "gif"]

  public static var directory: URL {
    let override = ProcessInfo.processInfo.environment["TWP_PORTAL_SHELF"]
    let dir = override.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
      ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("TWP Portal", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static var indexURL: URL { directory.appendingPathComponent("shelf.json") }

  private static func readIndex() -> [String: Meta] {
    (try? JSONDecoder().decode([String: Meta].self, from: Data(contentsOf: indexURL))) ?? [:]
  }

  private static func writeIndex(_ index: [String: Meta]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? encoder.encode(index).write(to: indexURL, options: [.atomic])
  }

  /// Newest first.
  public static func list() -> [ShelfItem] {
    lock.lock()
    defer { lock.unlock() }
    let index = readIndex()
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
    return files.filter { extensions.contains($0.pathExtension.lowercased()) }.compactMap { url -> ShelfItem? in
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
      else { return nil }
      let meta = index[url.lastPathComponent]
      return ShelfItem(
        id: url.lastPathComponent, url: url, prompt: meta?.prompt,
        created: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast,
        hasAlpha: (props[kCGImagePropertyHasAlpha] as? Bool) ?? false,
        width: (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, height: (props[kCGImagePropertyPixelHeight] as? Int) ?? 0,
        uploads: meta?.uploads ?? [:])
    }
    .sorted { $0.created > $1.created }
  }

  /// Finds an item by exact file name, name without extension, or unique prefix.
  public static func find(_ text: String) -> ShelfItem? {
    let wanted = text.lowercased()
    let items = list()
    if let exact = items.first(where: { $0.id.lowercased() == wanted || ($0.id as NSString).deletingPathExtension.lowercased() == wanted }) { return exact }
    let partial = items.filter { $0.id.lowercased().hasPrefix(wanted) }
    return partial.count == 1 ? partial[0] : nil
  }

  /// Saves a picture to the shelf under a readable name taken from `label`.
  @discardableResult
  public static func save(_ image: CGImage, purpose: ImagePurpose, label: String, prompt: String? = nil) throws -> ShelfItem {
    let encoded = try ImagePipeline.encode(image, purpose: purpose)
    let name = try write(encoded.data, label: label, ext: purpose == .sticker ? "png" : "jpg", prompt: prompt)
    guard let item = find(name) else { throw PortalError.image("Couldn't save to the Local shelf.") }
    return item
  }

  /// Copies a file from elsewhere on the Mac onto the shelf.
  @discardableResult
  public static func importFile(_ url: URL) throws -> ShelfItem {
    guard extensions.contains(url.pathExtension.lowercased()) else { throw PortalError.image("\(url.lastPathComponent) is not a picture the shelf can hold.") }
    if url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL, let already = find(url.lastPathComponent) { return already }
    let name = try write(try Data(contentsOf: url), label: (url.lastPathComponent as NSString).deletingPathExtension, ext: url.pathExtension.lowercased(), prompt: nil)
    guard let item = find(name) else { throw PortalError.image("Couldn't copy \(url.lastPathComponent) to the Local shelf.") }
    return item
  }

  private static func write(_ data: Data, label: String, ext: String, prompt: String?) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    var slug = label.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if slug.isEmpty { slug = "picture" }
    slug = String(slug.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    var name = "\(slug).\(ext)"
    var n = 2
    while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
      name = "\(slug)-\(n).\(ext)"
      n += 1
    }
    try data.write(to: directory.appendingPathComponent(name), options: [.atomic])
    if let prompt {
      var index = readIndex()
      index[name] = Meta(prompt: prompt)
      writeIndex(index)
    }
    changed()
    return name
  }

  public static func markUploaded(_ item: ShelfItem, origin: String, assetKey: String) {
    lock.lock()
    defer { lock.unlock() }
    var index = readIndex()
    var meta = index[item.id] ?? Meta(prompt: item.prompt)
    meta.uploads[origin] = assetKey
    index[item.id] = meta
    writeIndex(index)
    changed()
  }

  /// Moves the file to the Trash (recoverable), never deletes outright.
  public static func discard(_ item: ShelfItem) throws {
    try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
    lock.lock()
    defer { lock.unlock() }
    var index = readIndex()
    index[item.id] = nil
    writeIndex(index)
    changed()
  }
}
