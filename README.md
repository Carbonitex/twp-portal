# TWP Portal for Mac

A native macOS companion for [thinkwith.pictures](https://thinkwith.pictures): link it to your account once, then build and edit scenes from a terminal-style window, in plain words or with direct commands. The language model and the image model are Apple's, running on the Mac. No API key, no model download.

It is a client of the site's Scene Builder MCP endpoint (`/api/twp/mcp`), the same one any MCP-capable assistant can connect to; see <https://thinkwith.pictures/agents>. Everything it does is done as the signed-in user and spends their strain exactly as the website would.

## What is in here

| Target | What it is |
|---|---|
| `PortalCore` | Sign-in (OAuth 2.1, dynamic registration, PKCE, loopback redirect), the MCP client, the agent, the image pipeline |
| `twp` | Command-line front end: `twp login`, `twp scenes`, `twp ask "…"`, or `twp` alone for an interactive prompt |
| `TWPPortal` | The SwiftUI app: scene list, terminal, live scene preview |

## Requirements

- macOS 27 on Apple silicon with Apple Intelligence turned on.
- To build: the Command Line Tools (`xcode-select --install`). Xcode is not needed.

## Build and run

```sh
sh scripts/build.sh        # build/twp and build/TWPPortal
sh scripts/build.sh app    # also dist/TWP Portal.app and dist/TWP-Portal-mac.zip
open "dist/TWP Portal.app"
```

`swift build` also works on a healthy toolchain. `scripts/build.sh` calls `swiftc` directly, so it does not depend on SwiftPM.

## Using it

1. Choose **Link Account…** (or type `/login`). Your browser opens the site's own consent page; approve there. No password is typed into the app.
2. Type what you want: *"make a new scene called Harbour with that background"*, *"add an iron boots sticker in the middle of this scene"*, *"make it twice as big"*.
3. Or use commands, which never involve a model: `/scenes`, `/scene <id>`, `/preview`, `/upload <file> [sticker|background]`, `/cutout <file>`, `/imagine <text> [--background]`, `/call <tool> <json>`. `/help` lists them all.

Users only ever see production ("Online"), so the app shows no environment picker. Developers can point it elsewhere: `twp --env local …` (a server on `localhost:8798`) or `twp --env https://your.server …` for one run, or `twp use <…>` to make the CLI and the app both use it (the app then shows a picker with Online and that server, so you can switch back).

While nothing has been asked yet, the chat area shows a library of suggestion cards (`Starters.swift`), built from the user's own scene names, the focused scene and the Local shelf. Cards marked with a return arrow only look things up and run on click; cards marked with a pencil change the account or spend strain, so they are placed in the input to edit and confirm. The lightbulb beside the input brings the library back at any time, and typing `/` lists the matching commands above the input.

Publishing a scene, removing objects and destructive `api_call` operations always ask for confirmation first, whatever the model decided. In the CLI without a keyboard they are refused unless `--yes` is passed.

## How the agent fits a small model

Apple's on-device model has an 8,192-token context window, and the 28 tools' schemas alone are larger than that. So each request runs in two steps:

1. **Route.** A tool-less session picks up to four tools from a one-line catalogue (`AgentTool.routerHints`), using guided generation so it can only answer with real tool names.
2. **Act.** A fresh session gets just those tools. Schemas are converted from the server's JSON Schema at runtime (`SchemaBridge`), with descriptions clipped and, for the small model, only the everyday optional arguments offered (`AgentTool.everydayArguments`), because small models fill in optional arguments nobody asked for.

Tool output is compacted before the model sees it, and a short memory (recent turns, recent tool results, the focused scene) carries context between requests. When the model has a larger window (Private Cloud Compute is 32K), the router is skipped and full schemas are used.

Expect the on-device model to handle one- to three-step requests well and to struggle with long plans. `/call` reaches every tool with full arguments.

## Images and the Local shelf

Pictures stay on the Mac until the user uploads one. The Local shelf is a plain folder, `~/Pictures/TWP Portal` (override with `TWP_PORTAL_SHELF`), shown in the app's **Local** tab; `shelf.json` beside the files remembers prompts and which files were uploaded where. Files can be added or removed in Finder.

- `/imagine <text> [--background]` draws a picture and saves it to the shelf. `/cutout`, `/import` and dropping a file on the window also only touch the shelf. Nothing is uploaded and no strain is spent.
- `/upload <name>` (or **Upload** in the Local tab) is the one step that sends a picture to the TWP gallery, through `begin_image_upload` and a plain PUT to the one-time URL.
- The agent's `generate_image` tool follows the same rule with one exception: when the same request goes on to use the picture ("draw a chest and add it to this scene"), it uploads at once, because the user asked for it to be used. A bare "draw me a mushroom" stays local.
- Generation goes through Apple's Image Playground. The programmatic `ImageCreator` is tried first, but Apple deprecated it in macOS 27 and on the development Mac it always answers `notSupported`, so in practice the app opens the Image Playground sheet with the prompt and style filled in and takes the picture the user accepts. One picture per request. It needs the app window, so `/imagine` does not work from the bare `twp` binary.
- Stickers must be transparent, so generated stickers and `/cutout` go through Vision's foreground-subject mask.

## Private Cloud Compute

`/brain private-cloud` switches to Apple's server model. It reports available but refuses requests unless the app is signed with Apple's managed Private Cloud Compute entitlement (<https://developer.apple.com/private-cloud-compute/>).

## Where things are stored

- Sign-in: a build signed with a Developer ID keeps it in the login Keychain (service `pictures.thinkwith.portal`, one item per environment). An ad-hoc build (every local `scripts/build.sh`) keeps it in a `0600` file in `~/Library/Application Support/TWP Portal/` instead, because the Keychain treats each ad-hoc rebuild as a different app and would ask for the login password repeatedly. `TWP_PORTAL_TOKEN_FILE=1` forces the file, `=0` the Keychain.
- `~/Library/Application Support/TWP Portal/`: `config.json` (environment, model), `clients.json` (registered OAuth client ids).
- Access tokens last an hour; refresh tokens rotate on every use. The CLI and the app share one grant and refresh under a file lock, because replaying a spent refresh token revokes the grant.
- Revoke from the app (**Unlink**), `/logout`, or the website's Account window under Connected apps.

## Distributing it

`scripts/build.sh app` signs ad hoc, which runs on the Mac that built it. Other Macs need a Developer ID signature and notarization:

```sh
CODESIGN_IDENTITY="Developer ID Application: <name> (<team>)" sh scripts/build.sh app
xcrun notarytool submit dist/TWP-Portal-mac.zip --keychain-profile <profile> --wait
xcrun stapler staple "dist/TWP Portal.app"
```

## Development notes

- No Swift macros that need Xcode's plugins: no `@Generable` (schemas are built with `DynamicGenerationSchema`), no `@State` or `@Observable` in the app (`ObservableObject` instead).
- `TWP_PORTAL_RUN` holds newline-separated lines the app runs at launch, for demos and checks.

## Licence

MIT. See [LICENSE](LICENSE).
