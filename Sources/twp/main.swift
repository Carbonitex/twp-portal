import Foundation
import PortalCore

// twp: the terminal front end to TWP Portal.
//   twp                     interactive prompt
//   twp login | logout | whoami | scenes | tools | ...   (any slash command, without the slash)
//   twp ask "make a scene called Harbour"                 one request to the agent
//   twp --env <origin> ...  use another server for this run (e.g. http://localhost:8798)
//   twp use <origin>        remember a server (twp use prod to go back)

var args = Array(CommandLine.arguments.dropFirst())
var config = PortalConfig.load()

if let i = args.firstIndex(of: "--env"), i + 1 < args.count {
  config.environment = args[i + 1]
  args.removeSubrange(i...(i + 1))
}
if args.first == "use", args.count > 1 {
  guard PortalEnvironment.named(args[1]) != nil else {
    print("Unknown environment \"\(args[1])\". Use prod or a server origin such as http://localhost:8798.")
    exit(2)
  }
  config.environment = args[1]
  config.save()
  print("Now using \(args[1]).")
  exit(0)
}
guard let environment = PortalEnvironment.named(config.environment) else {
  print("Unknown environment \"\(config.environment)\".")
  exit(2)
}

let colour = isatty(STDOUT_FILENO) != 0
func paint(_ text: String, _ code: String) -> String { colour ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }

let failed = FailureFlag()
final class FailureFlag: @unchecked Sendable { var value = false }

let portal = Portal(environment: environment) { event in
  switch event {
  case .info(let text): print(text)
  case .error(let text):
    failed.value = true
    print(paint(text, "31"))
  case .assistant(let text): print(paint(text, "1"))
  case .toolCall(let name, let arguments): print(paint("→ \(name) \(arguments)", "2"))
  case .toolResult(let name, let text, let isError):
    let oneLine = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: "")
    print(paint("← \(name)\(isError ? " failed" : ""): \(oneLine.prefix(160))\(oneLine.count > 160 ? "…" : "")", isError ? "31" : "2"))
  case .image(let data, let caption):
    let safe = caption.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression).prefix(40)
    let isPNG = data.starts(with: [0x89, 0x50])
    let isJPEG = data.starts(with: [0xFF, 0xD8])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("twp-\(safe)-\(Int(Date().timeIntervalSince1970)).\(isPNG ? "png" : isJPEG ? "jpg" : "webp")")
    try? data.write(to: url)
    print("image saved: \(url.path)")
  case .json(let text): print(text)
  case .progress(let text):
    // A passing status line: shown on a terminal, left out of piped output.
    if colour { print(paint("  \(text)", "2")) }
  }
}

// Risky actions (publish, delete) are confirmed at the keyboard; when there is
// no keyboard (piped input, scripts) they are refused unless --yes was passed.
let assumeYes = args.contains("--yes")
args.removeAll { $0 == "--yes" }
portal.agent.confirm = { question in
  if assumeYes { return true }
  guard isatty(STDIN_FILENO) != 0 else {
    print("Refused without confirmation: \(question) (re-run with --yes to allow)")
    return false
  }
  print("\(question) [y/N] ", terminator: "")
  return ["y", "yes"].contains((readLine() ?? "").lowercased())
}

if let first = args.first {
  switch first {
  case "ask":
    await portal.handle(args.dropFirst().joined(separator: " "))
  case "help", "--help", "-h":
    print("twp [--env prod|<server origin>] [command]\n  twp use <env>     remember an environment\n  twp ask <words>   one request in plain words\n  twp               interactive prompt\n\n" + Portal.help)
  default:
    await portal.handle("/" + args.joined(separator: " "))
  }
  exit(failed.value ? 1 : 0)
}

print("TWP Portal · \(environment.displayName) (\(environment.origin.host ?? "")). /help lists commands, Ctrl-D quits.")
if await portal.auth.isSignedIn { await portal.handle("/whoami") } else { print("Not linked yet. Type /login.") }
while true {
  print(paint("› ", "36"), terminator: "")
  guard let line = readLine() else { break }
  if ["exit", "quit", "/exit", "/quit"].contains(line.trimmingCharacters(in: .whitespaces)) { break }
  await portal.handle(line)
}
