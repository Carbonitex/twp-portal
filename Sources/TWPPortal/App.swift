import AppKit
import ImagePlayground
import PortalCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct TWPPortalApp: App {
  @StateObject private var model = PortalModel()

  var body: some Scene {
    WindowGroup("TWP Portal") {
      RootView()
        .environmentObject(model)
        .frame(minWidth: 860, minHeight: 520)
        .preferredColorScheme(.dark)
    }
    .defaultSize(width: 1180, height: 740)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Portal") {
        Button("Refresh Scenes") { Task { await model.refreshAccount() } }.keyboardShortcut("r")
        Button("Refresh Preview") { Task { await model.refreshPreview() } }.keyboardShortcut("r", modifiers: [.command, .shift])
        Divider()
        Button("Show Local Pictures") { model.sidebarTab = .local }.keyboardShortcut("l")
        Button("Clear Conversation") { model.run("/clear") }.keyboardShortcut("k")
        Button("Show Commands") { model.run("/help") }.keyboardShortcut("/")
      }
    }
  }
}

enum Palette {
  static let background = Color(red: 0.07, green: 0.065, blue: 0.10)
  static let panel = Color(red: 0.10, green: 0.095, blue: 0.14)
  static let text = Color(red: 0.90, green: 0.88, blue: 0.94)
  static let dim = Color(red: 0.55, green: 0.53, blue: 0.62)
  static let accent = Color(red: 0.42, green: 0.85, blue: 0.78)
  static let user = Color(red: 0.98, green: 0.80, blue: 0.45)
  static let danger = Color(red: 1.0, green: 0.45, blue: 0.45)
}

struct RootView: View {
  @EnvironmentObject var model: PortalModel

  var body: some View {
    NavigationSplitView {
      Sidebar().navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    } detail: {
      HSplitView {
        Terminal().frame(minWidth: 420)
        if model.focus != nil { Inspector().frame(minWidth: 260, idealWidth: 360, maxWidth: 560) }
      }
    }
    .alert("Please confirm", isPresented: Binding(get: { model.confirmQuestion != nil }, set: { if !$0 { model.answer(false) } })) {
      Button("Cancel", role: .cancel) { model.answer(false) }
      Button("Yes, do it") { model.answer(true) }
    } message: {
      Text(model.confirmQuestion ?? "")
    }
    .imagePlaygroundSheet(isPresented: $model.playgroundShown, concept: model.playgroundConcept) { url in
      model.playgroundFinished(url)
    } onCancellation: {
      model.playgroundFinished(nil)
    }
    // The sheet opens in the art style the request asked for (flat illustration by default) rather than photo-real.
    .imagePlaygroundGenerationStyle(model.playgroundStyle, in: ImagePlaygroundStyle.all)
  }
}

// MARK: - Sidebar

struct Sidebar: View {
  @EnvironmentObject var model: PortalModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        if model.pickerEnvironments.count > 1 {
          Picker("Environment", selection: Binding(get: { model.environment }, set: { model.switchEnvironment($0) })) {
            ForEach(model.pickerEnvironments, id: \.self) { env in Text(env.displayName).tag(env) }
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .disabled(model.busy)
        }

        if let account = model.account {
          VStack(alignment: .leading, spacing: 4) {
            Text(account.nickname).font(.headline)
            ProgressView(value: min(account.strain, max(account.strainMax, 1)), total: max(account.strainMax, 1)).tint(Palette.accent)
            Text("Strain \(Int(account.strain)) of \(Int(account.strainMax))").font(.caption).foregroundStyle(.secondary)
          }
        } else if !model.signedIn {
          Text("Not linked").font(.headline)
          Text("Link this Mac to your thinkwith.pictures account. You approve it on the website; no password is typed here.")
            .font(.caption).foregroundStyle(.secondary)
          Text("New to thinkwith.pictures? Linking also creates your free account.")
            .font(.caption).foregroundStyle(.secondary)
          // Plain styling on purpose: with .fixedSize on the text above and a
          // .borderedProminent button here, the whole window rendered blank
          // while unlinked (macOS 27.2). Check the unlinked state after restyling.
          Button("Link Account…") { model.run("/login") }.disabled(model.busy)
        }

        Picker("Show", selection: $model.sidebarTab) {
          Text("Scenes").tag(SidebarTab.scenes)
          Text(model.shelf.isEmpty ? "Local" : "Local (\(model.shelf.count))").tag(SidebarTab.local)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }
      .padding(12)

      Divider()
      if model.sidebarTab == .local {
        LocalShelfView()
      } else if model.signedIn {
        SceneListView()
      } else {
        Text("Your scenes appear here once this Mac is linked.").font(.caption).foregroundStyle(.secondary).padding(12)
        Spacer()
      }
    }
  }
}

struct SceneListView: View {
  @EnvironmentObject var model: PortalModel

  var body: some View {
    TextField("Filter scenes", text: $model.sceneFilter).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.vertical, 8)
    List(selection: Binding(get: { model.focus }, set: { model.select($0) })) {
      ForEach(model.visibleScenes) { scene in
        HStack(spacing: 6) {
          Circle().fill(scene.isPublic ? Palette.accent : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
            .help(scene.isPublic ? "Public" : "Draft")
          Text(scene.name).lineLimit(1)
          Spacer()
          Text("\(scene.objectCount)").font(.caption).foregroundStyle(.secondary)
        }
        .tag(scene)
        .contextMenu {
          Button("Open in Browser") { model.openInBrowser(scene) }
          Button("Copy Scene ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(scene.id, forType: .string)
          }
        }
      }
    }
    .listStyle(.sidebar)
    .overlay { if model.scenes.isEmpty { Text("No scenes yet").foregroundStyle(.secondary) } }
    Divider()
    HStack {
      Text("\(model.scenes.count) scenes").font(.caption).foregroundStyle(.secondary)
      Spacer()
      Button("Unlink") { model.run("/logout") }.buttonStyle(.link).font(.caption).disabled(model.busy)
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
  }
}

/// Pictures kept on this Mac. Nothing here is in the TWP account until "Upload".
struct LocalShelfView: View {
  @EnvironmentObject var model: PortalModel
  private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

  var body: some View {
    if model.shelf.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Nothing here yet").font(.subheadline)
        Text("Pictures you draw with /imagine, cut out, or drop on the window are kept on this Mac. They reach your TWP account, and cost strain, only when you upload one.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .padding(12)
      Spacer()
    } else {
      ScrollView {
        LazyVGrid(columns: columns, spacing: 8) {
          ForEach(model.shelf) { item in
            ShelfCell(item: item, selected: model.selectedLocal?.id == item.id, uploaded: model.isUploaded(item), thumbnail: model.thumbnail(for: item))
              .onTapGesture { model.selectedLocal = model.selectedLocal?.id == item.id ? nil : item }
              .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
              .contextMenu { ShelfActions(item: item) }
          }
        }
        .padding(10)
      }
    }
    Divider()
    VStack(alignment: .leading, spacing: 6) {
      if let item = model.selectedLocal {
        Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
        Text("\(item.width)×\(item.height) · \(item.hasAlpha ? "transparent" : "opaque") · \(model.isUploaded(item) ? "uploaded" : "on this Mac only")")
          .font(.caption2).foregroundStyle(.secondary)
        HStack(spacing: 6) {
          Menu("Upload") {
            Button("As Sticker") { model.run("/upload \(item.name) sticker") }
            Button("As Background") { model.run("/upload \(item.name) background") }
          }
          .disabled(model.busy || !model.signedIn)
          .help(model.signedIn ? "Send this picture to your TWP gallery (spends strain)" : "Link your account to upload")
          Button("Cut Out") { model.run("/cutout \(item.name)") }.disabled(model.busy).help("Remove the background and save a new transparent copy")
          Button("Trash") { model.run("/discard \(item.name)") }.disabled(model.busy)
        }
        .controlSize(.small)
      } else {
        Text("\(model.shelf.count) on this Mac").font(.caption).foregroundStyle(.secondary)
      }
      Button("Show Folder in Finder") { NSWorkspace.shared.open(LocalShelf.directory) }.buttonStyle(.link).font(.caption)
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
  }
}

struct ShelfActions: View {
  @EnvironmentObject var model: PortalModel
  let item: ShelfItem

  var body: some View {
    Button("Upload as Sticker") { model.run("/upload \(item.name) sticker") }.disabled(!model.signedIn)
    Button("Upload as Background") { model.run("/upload \(item.name) background") }.disabled(!model.signedIn)
    Divider()
    Button("Cut Out Background") { model.run("/cutout \(item.name)") }
    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    Divider()
    Button("Move to Trash") { model.run("/discard \(item.name)") }
  }
}

struct ShelfCell: View {
  let item: ShelfItem
  let selected: Bool
  let uploaded: Bool
  let thumbnail: NSImage?

  var body: some View {
    ZStack {
      Checkerboard()
      if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().padding(3) }
    }
    .frame(height: 84)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Palette.accent : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1))
    .overlay(alignment: .topTrailing) {
      if uploaded {
        Image(systemName: "checkmark.icloud.fill").font(.system(size: 11)).foregroundStyle(Palette.accent).padding(4).help("Uploaded to your TWP gallery")
      }
    }
    .help(item.prompt ?? item.name)
  }
}

// MARK: - Terminal

struct Terminal: View {
  @EnvironmentObject var model: PortalModel
  @FocusState private var inputFocused: Bool
  // No @State here on purpose: in the macOS 27 SDK it is a macro that needs
  // Xcode's plugin, and this project builds with the Command Line Tools alone.

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(model.entries) { EntryRow(entry: $0).id($0.id) }
            // The suggestion library fills the empty chat, and comes back from the lightbulb by the input.
            if model.startersVisible, !model.busy {
              StarterLibrary { text in
                model.input = text
                inputFocused = true
              }
              .id("starters")
            }
            if model.busy {
              HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                if model.linking {
                  Text("Waiting for you in the browser…").foregroundStyle(Palette.dim)
                  Button("Open the page again") { model.reopenLinkPage() }.controlSize(.small)
                  Button("Cancel") { model.cancelLinking() }.controlSize(.small)
                } else {
                  Text("Working…").foregroundStyle(Palette.dim)
                }
              }
              .id("busy")
            }
          }
          .font(.system(size: 13, design: .monospaced))
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.startersRequested) { _, shown in
          if shown { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("starters", anchor: .bottom) } }
        }
        .onChange(of: model.entries.count) { _, _ in
          withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(model.busy ? AnyHashable("busy") : AnyHashable(model.entries.last?.id), anchor: .bottom) }
        }
      }

      if !model.commandMatches.isEmpty, !model.busy {
        CommandHelper { text in
          model.input = text
          inputFocused = true
        }
      }
      Divider().overlay(Palette.panel)
      HStack(spacing: 8) {
        Text("›").foregroundStyle(Palette.accent).font(.system(size: 15, weight: .bold, design: .monospaced))
        TextField(model.signedIn ? "Ask for something, or type / for commands" : "Type /login to link your account", text: $model.input)
          .textFieldStyle(.plain)
          .font(.system(size: 13, design: .monospaced))
          .foregroundStyle(Palette.text)
          .focused($inputFocused)
          .onSubmit { model.submit() }
          .onKeyPress(.upArrow) { model.recall(-1); return .handled }
          .onKeyPress(.downArrow) { model.recall(1); return .handled }
          .disabled(model.busy)
        Button {
          model.startersRequested.toggle()
        } label: {
          Image(systemName: model.startersVisible ? "lightbulb.fill" : "lightbulb").foregroundStyle(model.startersVisible ? Palette.user : Palette.dim)
        }
        .buttonStyle(.plain)
        .help("Suggestions")
        Menu(model.brain.rawValue) {
          ForEach(Brain.allCases, id: \.self) { brain in
            Button("\(brain.rawValue): \(PortalAgent.availability(brain).detail)") {
              model.run("/brain \(brain.rawValue)")
              model.brain = brain
            }
          }
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(Palette.dim)
        .help("Which Apple model answers plain-language requests")
      }
      .padding(.horizontal, 14).padding(.vertical, 11)
      .background(Palette.panel)
    }
    .background(Palette.background)
    .overlay { if model.dropTargeted { RoundedRectangle(cornerRadius: 8).stroke(Palette.accent, lineWidth: 2).padding(6) } }
    .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
      guard let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        DispatchQueue.main.async {
          // A dropped picture goes onto the Local shelf; uploading stays a separate, deliberate step.
          model.sidebarTab = .local
          model.run("/import \(url.path)")
        }
      }
      return true
    }
    .onAppear { inputFocused = true }
    .onChange(of: model.busy) { _, busy in if !busy { inputFocused = true } }
  }
}

struct EntryRow: View {
  let entry: Entry

  var body: some View {
    switch entry.kind {
    case .user:
      Text("› \(entry.text)").foregroundStyle(Palette.user).textSelection(.enabled).padding(.top, 6)
    case .assistant:
      Text(entry.text).foregroundStyle(Palette.text).font(.system(size: 13.5)).textSelection(.enabled).lineSpacing(2)
    case .info:
      Text(entry.text).foregroundStyle(Palette.text.opacity(0.85)).textSelection(.enabled)
    case .error:
      Text(entry.text).foregroundStyle(Palette.danger).textSelection(.enabled)
    case .toolCall:
      Text("→ \(entry.text)").foregroundStyle(Palette.accent.opacity(0.8)).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).lineLimit(4)
    case .toolResult:
      Text("← \(entry.text)").foregroundStyle(Palette.dim).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).lineLimit(3)
    case .toolError:
      Text("← \(entry.text)").foregroundStyle(Palette.danger.opacity(0.85)).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).lineLimit(4)
    case .json:
      Text(entry.text).foregroundStyle(Palette.dim).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
    case .image:
      VStack(alignment: .leading, spacing: 4) {
        if let image = entry.image {
          Image(nsImage: image).resizable().scaledToFit()
            .background(Checkerboard()).clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 420, maxHeight: 240, alignment: .leading)
            .onDrag { NSItemProvider(object: image) }
        }
        Text(entry.text).foregroundStyle(Palette.dim).font(.system(size: 11))
      }
    }
  }
}

/// Shows transparency behind stickers.
struct Checkerboard: View {
  var body: some View {
    Canvas { context, size in
      let cell: CGFloat = 8
      for row in 0...Int(size.height / cell) {
        for col in 0...Int(size.width / cell) where (row + col).isMultiple(of: 2) {
          context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(.white.opacity(0.07)))
        }
      }
    }
    .background(Color.black.opacity(0.25))
  }
}

// MARK: - Inspector

struct Inspector: View {
  @EnvironmentObject var model: PortalModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let scene = model.focus {
        HStack(alignment: .firstTextBaseline) {
          Text(scene.name).font(.headline).lineLimit(2)
          Spacer()
          Text(scene.isPublic ? "Public" : "Draft").font(.caption)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((scene.isPublic ? Palette.accent : Color.secondary).opacity(0.2), in: Capsule())
        }
        ZStack {
          RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3))
          if let preview = model.preview {
            Image(nsImage: preview).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
          } else if model.previewLoading {
            ProgressView()
          } else if let error = model.previewError {
            Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
          }
        }
        .frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .topTrailing) { if model.previewLoading, model.preview != nil { ProgressView().controlSize(.small).padding(8) } }

        Text("\(scene.objectCount) object\(scene.objectCount == 1 ? "" : "s") · id \(scene.id)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        HStack {
          Button("Refresh") { Task { await model.refreshPreview() } }.disabled(model.previewLoading)
          Button("Open in Browser") { model.openInBrowser(scene) }
          Spacer()
          Button("Details") { model.run("/scene \(scene.id)") }.disabled(model.busy)
        }
        Text("Requests like “add a lantern sticker near the door” apply to this scene.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Spacer()
      }
    }
    .padding(14)
    .background(Palette.panel)
  }
}
