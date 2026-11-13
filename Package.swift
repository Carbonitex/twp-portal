// swift-tools-version: 6.0
import PackageDescription

// TWP Portal: a native macOS companion for thinkwith.pictures.
//   PortalCore  sign-in (OAuth + PKCE), the MCP client, the on-device agent
//   twp         command-line front end (login, call, ask, repl)
//   TWPPortal   the SwiftUI app (terminal + scene preview)
// Builds with the Command Line Tools alone (no Xcode): `swift build -c release`.
// FoundationModels macros (@Generable) need Xcode's macro plugin, so the code
// uses DynamicGenerationSchema instead and stays macro-free on purpose.
let package = Package(
  name: "TWPPortal",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "twp", targets: ["twp"]),
    .executable(name: "TWPPortal", targets: ["TWPPortal"]),
  ],
  targets: [
    .target(name: "PortalCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "twp", dependencies: ["PortalCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "TWPPortal", dependencies: ["PortalCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
