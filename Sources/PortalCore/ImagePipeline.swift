import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import ImagePlayground
import UniformTypeIdentifiers
import Vision

public enum ImagePurpose: String, Sendable {
  case background, sticker
}

public struct UploadedImage: Sendable {
  public let assetKey: String
  public let width: Int
  public let height: Int
  public let hasAlpha: Bool
  public var json: JSONValue {
    ["assetKey": .string(assetKey), "width": .number(String(width)), "height": .number(String(height)), "hasAlpha": .bool(hasAlpha)]
  }
}

/// Local image work: generate with Apple's on-device image model, cut a subject
/// out of its background with Vision (TWP stickers must be transparent), and
/// upload bytes to the user's TWP gallery.
public enum ImagePipeline {
  public static let styleNames = ["illustration", "animation", "sketch"]

  /// Programmatic generation through ImagePlayground's `ImageCreator`.
  /// Apple deprecated this entry point in macOS 27 in favour of the Image
  /// Playground sheet, and it refuses to run outside a foreground app, so
  /// callers must be ready for `PortalError.image` and fall back to the sheet.
  public static func generate(prompt: String, style: String = "illustration", count: Int = 1) async throws -> [CGImage] {
    var images: [CGImage] = []
    do {
      let creator = try await ImageCreator()
      let wanted: ImagePlaygroundStyle = style == "animation" ? .animation : style == "sketch" ? .sketch : .illustration
      let chosen = creator.availableStyles.contains(wanted) ? wanted : (creator.availableStyles.first ?? wanted)
      for try await image in creator.images(for: [.text(prompt)], style: chosen, limit: max(1, min(count, 4))) {
        images.append(image.cgImage)
      }
      guard !images.isEmpty else { throw PortalError.image("The image model returned nothing.") }
      return images
    } catch {
      // Keep whatever arrived before a failure part-way through a batch.
      if !images.isEmpty { return images }
      FileHandle.standardError.write(Data("ImageCreator failed: \(error)\n".utf8))
      guard let known = error as? ImageCreator.Error else { throw PortalError.image("Image generation failed (\(error.localizedDescription)).") }
      switch known {
      case .notSupported, .unavailable:
        throw PortalError.image("On-device image generation is not available to this process. Use the Image Playground window in the app instead.")
      case .backgroundCreationForbidden:
        throw PortalError.image("Image generation only runs while the app is in front.")
      default:
        throw PortalError.image("Image generation failed (\(known)).")
      }
    }
  }

  /// Lifts the foreground subject off its background and crops to it.
  public static func cutout(_ image: CGImage) throws -> CGImage {
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: image)
    try handler.perform([request])
    guard let result = request.results?.first, !result.allInstances.isEmpty else {
      throw PortalError.image("Couldn't find a subject to cut out of that image.")
    }
    let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
    let ci = CIImage(cvPixelBuffer: buffer)
    guard let out = CIContext().createCGImage(ci, from: ci.extent) else { throw PortalError.image("Couldn't render the cutout.") }
    return out
  }

  // MARK: Pixel helpers (stickers from the Qwen engine, edits and fills)

  private static func bitmap(width: Int, height: Int) throws -> CGContext {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PortalError.image("Couldn't allocate a picture buffer.") }
    return ctx
  }

  public static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
    if image.width == width, image.height == height { return image }
    let ctx = try bitmap(width: width, height: height)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let out = ctx.makeImage() else { throw PortalError.image("Couldn't resize the picture.") }
    return out
  }

  /// The picture with one rectangle (bottom-left pixel coordinates) painted a flat colour.
  static func painted(_ image: CGImage, rect: CGRect, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
    let ctx = try bitmap(width: image.width, height: image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    ctx.fill(rect)
    guard let out = ctx.makeImage() else { throw PortalError.image("Couldn't mark the picture.") }
    return out
  }

  /// `top` inside `rect`, `bottom` everywhere else, with a soft edge a few pixels wide so no seam shows.
  static func blend(_ top: CGImage, over bottom: CGImage, inside rect: CGRect) throws -> CGImage {
    let extent = CGRect(x: 0, y: 0, width: bottom.width, height: bottom.height)
    let feather = max(3, Double(min(bottom.width, bottom.height)) * 0.008)
    let mask = CIImage(color: .white).cropped(to: rect.insetBy(dx: -feather, dy: -feather))
      .composited(over: CIImage(color: .black).cropped(to: extent))
      .clampedToExtent().applyingGaussianBlur(sigma: feather).cropped(to: extent)
    let mixed = CIImage(cgImage: top).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(cgImage: bottom), kCIInputMaskImageKey: mask])
    guard let out = CIContext().createCGImage(mixed, from: extent) else { throw PortalError.image("Couldn't blend the fill into the picture.") }
    return out
  }

  private static func alphaBytes(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return nil
    default: break
    }
    let w = image.width, h = image.height
    guard let ctx = try? bitmap(width: w, height: h), let data = { ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return ctx.data }() else { return nil }
    let rgba = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var bytes = [UInt8](repeating: 0, count: w * h)
    for i in 0..<(w * h) { bytes[i] = rgba[i * 4 + 3] }
    return (bytes, w, h)
  }

  /// True when a meaningful share of the picture is see-through (not just an unused alpha channel).
  public static func hasTransparency(_ image: CGImage) -> Bool {
    guard let alpha = alphaBytes(image) else { return false }
    var clear = 0
    for a in alpha.bytes where a < 16 { clear += 1 }
    return clear * 200 > alpha.bytes.count
  }

  /// Crops away the empty margin around a transparent sticker, leaving a few pixels of breathing room.
  public static func trimTransparent(_ image: CGImage) -> CGImage {
    guard let alpha = alphaBytes(image) else { return image }
    var minX = alpha.width, minY = alpha.height, maxX = -1, maxY = -1
    for y in 0..<alpha.height {
      let row = y * alpha.width
      for x in 0..<alpha.width where alpha.bytes[row + x] > 12 {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
      }
    }
    guard maxX >= minX, maxY >= minY else { return image }
    let pad = 6
    let rect = CGRect(x: max(0, minX - pad), y: max(0, minY - pad), width: min(alpha.width, maxX + pad + 1) - max(0, minX - pad), height: min(alpha.height, maxY + pad + 1) - max(0, minY - pad))
    return image.cropping(to: rect) ?? image
  }

  public static func load(_ url: URL) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
      throw PortalError.image("Couldn't read an image from \(url.lastPathComponent).")
    }
    return image
  }

  /// PNG keeps transparency (stickers); JPEG is far smaller for opaque backgrounds.
  public static func encode(_ image: CGImage, purpose: ImagePurpose) throws -> (data: Data, contentType: String) {
    let png = purpose == .sticker
    let data = NSMutableData()
    let type = png ? UTType.png : UTType.jpeg
    guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw PortalError.image("Couldn't encode the image.") }
    CGImageDestinationAddImage(dest, image, png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw PortalError.image("Couldn't encode the image.") }
    return (data as Data, png ? "image/png" : "image/jpeg")
  }

  /// Uploads through the MCP's one-time upload URL (`begin_image_upload`, then a plain PUT).
  public static func upload(_ data: Data, contentType: String, purpose: ImagePurpose, mcp: MCPClient) async throws -> UploadedImage {
    let begun = try await mcp.call("begin_image_upload", ["purpose": .string(purpose.rawValue), "contentType": .string(contentType)])
    guard !begun.isError, let urlText = begun.json?["uploadUrl"]?.stringValue, let url = URL(string: urlText) else {
      throw PortalError.tool(begun.text.isEmpty ? "The server refused the upload." : begun.text)
    }
    var req = URLRequest(url: url)
    req.httpMethod = "PUT"
    req.setValue(contentType, forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 180
    let (body, resp) = try await URLSession.shared.upload(for: req, from: data)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    let json = (try? JSONValue.parse(body)) ?? .null
    guard (200..<300).contains(status), let key = json["assetKey"]?.stringValue else {
      throw PortalError.http(status, json["error"]?.stringValue ?? json["message"]?.stringValue ?? "upload failed")
    }
    return UploadedImage(assetKey: key, width: json["width"]?.intValue ?? 0, height: json["height"]?.intValue ?? 0, hasAlpha: json["hasAlpha"]?.boolValue ?? false)
  }

  /// Upload a file from disk. PNG, JPEG and WebP go up byte-for-byte; anything
  /// else ImageIO can read (HEIC, TIFF…) is re-encoded first.
  public static func uploadFile(_ url: URL, purpose: ImagePurpose, mcp: MCPClient) async throws -> UploadedImage {
    let passthrough = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"]
    if let type = passthrough[url.pathExtension.lowercased()] {
      return try await upload(try Data(contentsOf: url), contentType: type, purpose: purpose, mcp: mcp)
    }
    let encoded = try encode(try load(url), purpose: purpose)
    return try await upload(encoded.data, contentType: encoded.contentType, purpose: purpose, mcp: mcp)
  }
}
