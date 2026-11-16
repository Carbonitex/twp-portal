# Plan: optional OpenRouter provider (text and pictures)

Asked for: "allowing them to configure openrouter to serve image and text requests in the TWP portal".

OpenRouter is opt-in, like the local model server and the Qwen server. Apple's on-device model and
Image Playground stay the defaults. Nothing leaves the Mac for OpenRouter unless the user stores a key
and picks an OpenRouter brain or picture engine.

## Docs read (2026-11-16)

- Image generation: <https://openrouter.ai/docs/features/multimodal/image-generation>. The current
  docs describe a dedicated **Images API**, `POST /api/v1/images`, not chat completions with
  `modalities`. The page does not mention the chat-completions route at all
  (<https://openrouter.ai/docs/guides/overview/multimodal/image-generation> says the same). Request:
  `{model, prompt, resolution, aspect_ratio, background: auto|transparent|opaque, output_format, n, seed,
  input_references: [{type: "image_url", image_url: {url: <https or data URL>}}]}`. Response:
  `{data: [{b64_json, media_type}], usage: {cost}}`. The parameters each model accepts are listed by
  `GET /api/v1/images/models` (`supported_parameters`), and prices by
  `GET /api/v1/images/models/<id>/endpoints`.
  **This differs from the brief**, which expected chat completions with `modalities` and data-URL
  answers. I followed the docs: the Images API states which models accept `background: transparent`
  and input pictures, so the portal can ask for only what a model supports.
- Limits and credit: <https://openrouter.ai/docs/api-reference/limits>. `GET /api/v1/key` gives
  `limit`, `limit_remaining`, `usage`. `GET /api/v1/credits` gives `total_credits` and `total_usage`;
  both work with an ordinary key (checked live).
- Errors: <https://openrouter.ai/docs/api-reference/errors>. `{error: {code, message, metadata}}`;
  401 bad key, 402 no credit, 403 moderation (`metadata.reasons`) or budget (`metadata.limit_source`),
  408, 429 (optional `Retry-After`), 502 model down, 503 no provider meets the routing needs. Errors
  can also arrive inside an HTTP 200 body.
- Attribution: <https://openrouter.ai/docs/app-attribution>. `HTTP-Referer` (the app URL, the
  identifier) and `X-OpenRouter-Title` (`X-Title` still accepted). Sent as
  `https://github.com/Carbonitex/twp-portal` and "TWP Portal".
- Chat completions with tools: OpenAI-compatible at `https://openrouter.ai/api/v1/chat/completions`;
  `GET /api/v1/models` lists `supported_parameters`, which includes `"tools"` for tool-capable models.

## Defaults, checked against the live lists

- **Text: `anthropic/claude-haiku-5.5`.** 406 of 469 listed models report `tools`. Shortlist at the
  low price point ($0.10 in / $0.50 out per million tokens, 1M context): Claude Haiku 5.5 and
  `meta/muse-ember` (the model TWP's own script generator switched to last week). In a probe with
  two tools ("move the lantern in scene <id>"), both correctly called `get_scene` first. Haiku did it
  without a preamble and cost half as much ($0.0001 against $0.0002). Haiku is the default;
  muse-ember is a good alternative.
- **Pictures: `qwen/qwen-image-2.1-turbo`.** $0.0184 a picture at 1K, flat. It is the same model
  family as the optional local Qwen engine (and TWP's icon forge), so prompts tuned for it carry over.
  It accepts up to 10 input pictures, so edit and fill work. It cannot draw transparency, so stickers
  go through the existing Vision cut-out. Alternatives the portal handles without changes:
  `bytedance-seed/seedream-5-5` ($0.02, plus $0.008 per input picture; draws `background: transparent`, so
  stickers get real alpha; offered by name as `/pictures model seedream`. Seedream 5 Flash lists the same
  parameter but refuses it without an input picture) and `google/gemini-3.1-flash-image` (priced per token).

## Design

### Key (`Auth.swift`)
- A small `SecretStore` beside `GrantStore`, with the same storage rule: a 0600 file
  (`openrouter-key`) in `~/Library/Application Support/TWP Portal/` for ad-hoc builds, the Keychain
  (service `pictures.thinkwith.portal`, account `openrouter`) for Developer-ID builds. Never in
  `config.json`.
- Fallback: `OPENROUTER_API_KEY` from the environment when nothing is stored.
- `TWP_PORTAL_HOME` overrides the support folder (for tests that must not touch the app's config).

### OpenRouter client (`OpenRouter.swift`, new)
- One fixed base URL, `https://openrouter.ai/api/v1`, hard-coded and not configurable, so the key goes
  only there. Requests are built fresh and carry only the OpenRouter key; the TWP token lives in
  `PortalAuth` and is never read here.
- `explain(status, json)` turns every error into one plain sentence: no key, key refused, out of credit
  (key limit or account), rate limited (with the wait), refused by moderation (with reasons), model
  without tool support, model down or unknown.
- Model lists (`/models`, `/images/models`) are cached for the session. Choosing a model checks that it
  exists and, for text, that it supports tools.
- `status()` for `/openrouter`: masked key and its source, models, credit (key limit remaining, and
  account balance from `/credits`).
- `generateImage(...)`: the Images API, sending only parameters the model lists (aspect ratio,
  resolution 1K, `background: transparent` for stickers, PNG), with reference pictures as data URLs.

### Text (`Agent.swift`, `LocalBrain.swift`)
- A new `Brain.openrouter` case rather than `local` pointed at OpenRouter: it has its own key, model
  and error wording, and switching between a local server and OpenRouter should not lose either
  setting.
- `LocalBrain`'s 16-round tool loop is split from server discovery: `LocalBrain.run(server:…)` takes a
  `ChatServer` (URL, model, extra headers, name, error explainer). The local brain and OpenRouter both
  call it, so there is one loop.
- The agent treats both "chat-completions" brains alike: every tool with full schemas, no router.
- `/brain openrouter`; `/brain model <id>` sets the OpenRouter model while that brain is selected (the
  local model otherwise); `/brain model auto` returns to the default.
- `/openrouter test`: one short request through the same loop with one harmless local tool, to show
  that the key, the model and tool calling work without a TWP account.

### Pictures (`PictureEngine.swift`)
- `PictureEngine.openrouter`. `canEdit` (every engine but Apple's) replaces `isQwen` wherever it meant
  "can edit and fill" (agent `edit_local_picture` tool, Edit/Fill buttons, the repaint suggestion, the
  agent's image generator). `isQwen` stays for the Qwen server's light and polling.
- Draw: stickers ask for `background: transparent` when the model offers it; anything that comes back
  opaque goes through `ImagePipeline.cutout`, then is trimmed. Backgrounds ask for 3:2.
- Edit: the picture goes in as a PNG data URL, at the supported aspect ratio nearest its own; the answer
  is resized back to the original's working size. A sticker that comes back opaque is cut out again.
  Found in testing: a transparent sticker reaches the model on black, and the answer came back on a noisy
  dark ground that the cut-out could not separate (about 100k half-transparent pixels round the subject).
  Stickers are therefore flattened onto white before an OpenRouter edit; after that change the edited
  sticker's edge was as clean as the original's.
- Fill: unchanged method (magenta box, then `ImagePipeline.blend` through the feathered mask), so pixels
  outside the box never change, whatever the model returns.
- `/pictures openrouter`, `/pictures model <id|auto>`.

### Commands and UI
- `/openrouter` (status), `/openrouter key <key>`, `/openrouter key clear`, `/openrouter test`.
- In the app a `/openrouter key …` line is masked in the transcript and kept out of the input history.
- Brain menu and picture-light menu gain OpenRouter entries, disabled with "set a key with
  /openrouter key <key>" when no key is set.
- `SlashCommand.all` and `/help` gain the new commands.
- Privacy: the first time either OpenRouter option is chosen, one notice says prompts, tool results
  and pictures go to OpenRouter and the model's provider (`openrouterNoticeShown` in config).

## Files

- `Sources/PortalCore/OpenRouter.swift` (new), `Auth.swift`, `LocalBrain.swift`, `Agent.swift`,
  `PictureEngine.swift`, `Portal.swift`
- `Sources/TWPPortal/App.swift`, `Model.swift`, `Starters.swift`
- `README.md`

## Testing (CLI only; the app stays untouched while Matt uses it)

All runs use `TWP_PORTAL_HOME` and `TWP_PORTAL_SHELF` under `/tmp`, so the app's config, key and shelf
never change. There is no staging link on this Mac, so TWP-account tools are not exercised. Budget: a
handful of cheap text calls and at most six pictures.
