# Lechuza

On-device meeting recorder and dictation for macOS. Bun workspaces (`packages/contracts`, `apps/desktop` Electron main, `apps/web` React renderer) plus `engine/`, the Swift helper `lechuza-engine`. Read `README.md` for the architecture.

- Checks: `bun run typecheck`, `bun test`, and `swift test --package-path engine`. The engine's speech test downloads Parakeet v3 (~470 MB) on its first run.
- Main owns all state (`apps/desktop/src/meetings.ts`). The renderer sends intents through `window.lechuza` and renders the broadcast `AppState`. Add a capability in this order: contracts type + channel, preload, main handler, renderer.
- The app and engine speak JSON lines on stdio. A message lives in three places that change together: `packages/contracts/src/engine.ts`, `engine/Sources/LechuzaEngine/Protocol.swift`, and one example in `packages/contracts/fixtures/engine-protocol.json`, which both sides' tests decode. `dictation.*` is reserved for dictation (#4).
- macOS grants Microphone and System Audio Recording to the app that launched the engine. Packaged, that is Lechuza, because main spawns `Contents/Resources/lechuza-engine` as its child. Under `bun run dev` it is the terminal's app (T3 Code), so the prompts never name Lechuza there; prove permission behaviour on a `bun run dist` build launched with `open`.
- Signed builds use the hardened runtime: `apps/desktop/build/entitlements.mac.plist` must keep `com.apple.security.device.audio-input`, and `build.mac.extendInfo` in `apps/desktop/package.json` both usage strings, or macOS blocks capture with no prompt.
- This Mac has a Developer ID identity, which electron-builder picks first. Local `bun run dist` signs with Apple Development: `CSC_NAME="Apple Development: <name>" bun run dist`.
- Every style is in `apps/web/src/index.css`, under semantic class names. Components carry class names only.
- Electron won't start if `ELECTRON_RUN_AS_NODE=1` is set (T3 Code terminals set it). Prefix commands with `env -u ELECTRON_RUN_AS_NODE`.
- Bun's bundler bakes `__dirname` in at build time. Resolve app files from `app.getAppPath()`.
- `LECHUZA_MEETINGS_DIR` points the app at another meetings folder. Use it for demos and screenshots, so real meetings stay out of them.
