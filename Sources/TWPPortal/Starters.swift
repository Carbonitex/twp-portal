import PortalCore
import SwiftUI

/// One suggestion card. `sends` cards run on click (they only look things up);
/// the rest are placed in the input for the user to edit and confirm with
/// Return, because they change the account or spend strain.
struct StarterPrompt: Identifiable {
  let id = UUID()
  let icon: String
  let title: String
  let text: String
  var sends = false
}

struct StarterGroup: Identifiable {
  let id = UUID()
  let title: String
  let prompts: [StarterPrompt]
}

struct SlashCommand: Identifiable {
  let name: String
  let usage: String
  let summary: String
  var id: String { name }

  static let all: [SlashCommand] = [
    .init(name: "/scenes", usage: "/scenes [text]", summary: "List your scenes"),
    .init(name: "/scene", usage: "/scene <id>", summary: "Details and objects of one scene"),
    .init(name: "/focus", usage: "/focus <id>", summary: "Make \"this scene\" mean that scene"),
    .init(name: "/preview", usage: "/preview [id]", summary: "Render a picture of a scene"),
    .init(name: "/game", usage: "/game [on|off|reload|guest|me|<scene id>]", summary: "Show the live game beside the chat"),
    .init(name: "/open", usage: "/open [id]", summary: "Open a scene in the browser"),
    .init(name: "/imagine", usage: "/imagine <text> [--background]", summary: "Draw a picture, kept on this Mac"),
    .init(name: "/cutout", usage: "/cutout <name or file>", summary: "Remove a picture's background"),
    .init(name: "/edit", usage: "/edit <name or file> <what to change>", summary: "Repaint a picture as instructed (Qwen engine)"),
    .init(name: "/fill", usage: "/fill <name or file> <area> <what>", summary: "Paint something into part of a picture (Qwen engine)"),
    .init(name: "/pictures", usage: "/pictures [apple|qwen-turbo|qwen]", summary: "Which engine draws pictures"),
    .init(name: "/local", usage: "/local", summary: "Pictures on this Mac"),
    .init(name: "/import", usage: "/import <file>", summary: "Copy a picture onto the Local shelf"),
    .init(name: "/upload", usage: "/upload <name or file> [sticker|background]", summary: "Send a picture to your TWP gallery"),
    .init(name: "/discard", usage: "/discard <name>", summary: "Move a Local picture to the Trash"),
    .init(name: "/whoami", usage: "/whoami", summary: "Account and strain"),
    .init(name: "/tools", usage: "/tools", summary: "Every tool the server offers"),
    .init(name: "/call", usage: "/call <tool> <json>", summary: "Run one tool directly"),
    .init(name: "/brain", usage: "/brain [on-device|private-cloud|local]", summary: "Which model answers"),
    .init(name: "/clear", usage: "/clear", summary: "Forget the conversation so far"),
    .init(name: "/login", usage: "/login", summary: "Link this Mac to your TWP account"),
    .init(name: "/logout", usage: "/logout", summary: "Unlink this Mac"),
    .init(name: "/help", usage: "/help", summary: "All commands"),
  ]
}

extension PortalModel {
  /// Suggestions for the empty chat, built from what the user actually has:
  /// their scene names, the focused scene, the pictures on the Local shelf.
  var starterGroups: [StarterGroup] {
    guard signedIn else {
      return [StarterGroup(title: "Get started", prompts: [
        .init(icon: "link", title: "Link my account", text: "/login", sends: true),
        .init(icon: "paintbrush", title: "Draw a picture first", text: "/imagine a small red windmill"),
        .init(icon: "questionmark.circle", title: "What can I type here?", text: "/help", sends: true),
      ])]
    }

    let scene = focus ?? starterScene
    let here = focus != nil ? "this scene" : scene.map { "the scene \"\($0.name)\"" }
    var groups: [StarterGroup] = []

    var look: [StarterPrompt] = [
      .init(icon: "gauge.with.dots.needle.33percent", title: "Check my strain", text: "How much strain do I have left?", sends: true),
      .init(icon: "list.bullet", title: "List my scenes", text: "/scenes", sends: true),
    ]
    if let scene {
      look.insert(.init(icon: "eye", title: "Open \(scene.name)", text: "/scene \(scene.id)", sends: true), at: 0)
      look.append(.init(icon: "photo", title: "Show me how \(scene.name) looks", text: "/preview \(scene.id)", sends: true))
    }
    groups.append(StarterGroup(title: "Look around", prompts: look))

    var build: [StarterPrompt] = []
    if let here {
      build.append(.init(icon: "plus.square.on.square", title: "Add a sticker from the packs", text: "Add an iron boots sticker from the packs to the middle of \(here)"))
      build.append(.init(icon: "wand.and.stars", title: "Draw something and place it", text: "Draw a treasure chest sticker and add it near the bottom middle of \(here)"))
      build.append(.init(icon: "arrow.up.left.and.arrow.down.right", title: "Move or resize an object", text: "In \(here), make the [object name] half as big and move it to the bottom right"))
    }
    build.append(.init(icon: "square.and.pencil", title: "Start a new scene", text: "Draw a forest clearing background and make a new scene called Forest Clearing with it"))
    groups.append(StarterGroup(title: "Build", prompts: build))

    var pictures: [StarterPrompt] = [
      .init(icon: "paintbrush", title: "Draw a sticker", text: "/imagine a brass lantern"),
      .init(icon: "mountain.2", title: "Draw a background", text: "/imagine a misty harbour at dawn --background"),
    ]
    if let newest = shelf.first(where: { !isUploaded($0) }) {
      pictures.append(.init(icon: "icloud.and.arrow.up", title: "Upload \(newest.name)", text: "/upload \(newest.name) \(newest.suggestedPurpose.rawValue)"))
    }
    if pictureEngine.isQwen, let newest = shelf.first {
      pictures.append(.init(icon: "paintpalette", title: "Repaint \(newest.name)", text: "/edit \(newest.name) make it night time with a full moon"))
    }
    groups.append(StarterGroup(title: "Pictures (kept on this Mac until you upload)", prompts: pictures))
    return groups
  }

  /// Commands matching what is being typed after a "/", for the helper above the input.
  var commandMatches: [SlashCommand] {
    guard input.hasPrefix("/"), !input.contains(" ") else { return [] }
    let typed = input.lowercased()
    let hits = SlashCommand.all.filter { $0.name.hasPrefix(typed) }
    return hits.count == 1 && hits[0].name == typed ? [] : hits
  }
}

struct StarterLibrary: View {
  @EnvironmentObject var model: PortalModel
  /// Fills the input and returns focus to it.
  let fill: (String) -> Void
  private let columns = [GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 8, alignment: .top)]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(model.starterGroups) { group in
        VStack(alignment: .leading, spacing: 6) {
          Text(group.title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.dim).kerning(0.6)
          LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(group.prompts) { prompt in
              Button {
                if prompt.sends { model.run(prompt.text) } else { fill(prompt.text) }
              } label: {
                HStack(alignment: .top, spacing: 10) {
                  Image(systemName: prompt.icon).font(.system(size: 14)).foregroundStyle(Palette.accent).frame(width: 20)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.text)
                    Text(prompt.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.dim).lineLimit(2).multilineTextAlignment(.leading)
                  }
                  Spacer(minLength: 0)
                  Image(systemName: prompt.sends ? "return" : "pencil").font(.system(size: 10)).foregroundStyle(Palette.dim.opacity(0.7))
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 8))
              }
              .buttonStyle(.plain)
              .disabled(model.busy)
              .help(prompt.sends ? "Runs right away" : "Puts this in the input so you can change it, then press Return")
            }
          }
        }
      }
    }
    .font(.system(size: 13))
    .padding(.top, 10)
  }
}

struct CommandHelper: View {
  @EnvironmentObject var model: PortalModel
  let fill: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(model.commandMatches.prefix(8)) { command in
        Button {
          fill(command.usage.contains("<") || command.usage.contains("[") ? command.name + " " : command.name)
        } label: {
          HStack(spacing: 12) {
            Text(command.usage).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.accent)
            Text(command.summary).font(.system(size: 12)).foregroundStyle(Palette.dim)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 14).padding(.vertical, 5)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.panel.opacity(0.9))
  }
}
