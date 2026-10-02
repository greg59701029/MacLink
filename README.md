# MacLink

MacLink is an MIT-licensed iPhone app and Mac companion for connecting to **your own Mac** over a private Tailscale network. The paired iPhone can view and control the Mac desktop, browse and transfer files, use an optional local Jarvis model, and continue tasks through the official Codex app-server on that Mac. The Codex integration uses the user's own Codex installation and account; it is not the same session or memory as a dot/assistant. MacLink does not bundle Codex, a model, or credentials.

## Source layout

- `Sources/MacLink/`, `Assets.xcassets/`, `AppIcons/`, `Info.plist`, `PrivacyInfo.xcprivacy`, `MacLink.xcodeproj/`: iPhone app, deployment target iOS 17+, bundle ID `com.adam.maclink`.
- `MacCompanionApp/`: macOS companion UI, currently built for Apple Silicon arm64 and macOS 14+.
- `MacBridge/`: private HTTPS companion service, pairing, screen/input helpers and local Codex bridge.
- `Tests/`, `scripts/`: source tests and build helpers.

## Build and install

Use a Mac with compatible Xcode to open `MacLink.xcodeproj` and build the `MacLink` scheme. For installation on your own iPhone, select your own Apple development team and a unique bundle ID if needed. Never commit signing assets or provisioning profiles. Run the independent source checks with `zsh scripts/test-private-addresses.sh`, `zsh scripts/test-pairing-session.sh`, and `python3 -m unittest discover -s MacBridge -p 'test_*.py'` (Python 3.10+).

For the Mac companion, compile `MacCompanionApp/CompanionApp.swift` and the two helpers from `MacBridge/input_helper.swift` and `MacBridge/screen_stream.swift` for your target architecture, or use a separately distributed signed and Apple-notarized Mac companion ZIP. The published source tree contains no Apple signing key, certificate, provisioning profile, or pre-authorized pairing state. See `MacBridge/SETUP.md` for dependencies and first-run steps. A reviewer or user should install it on **their own Mac**; do not share someone else's pairing code or access token.

At runtime the Mac requires Python 3.10+ with SSL, an OpenSSL command supporting `req -addext`, and Tailscale on both Mac and iPhone in the same private network. Desktop and file features do not require Jarvis or Codex. Jarvis text responses require a separately installed and configured compatible local Jarvis/Ollama runtime. Codex tasks require a separately installed, signed-in official Codex app/CLI on that Mac. Before sending a new Codex task, the iPhone asks for consent to send content to OpenAI; ongoing Codex processing may involve task-related files and conversations.

The companion listens only on a private address, uses a one-time pairing code, pins the TLS certificate on iPhone, and stores a per-device token. macOS Screen Recording and Accessibility permissions remain under the Mac owner's control. Pair only devices you control, use non-sensitive data for initial tests, and stop the companion when remote access is not needed. Read `MacBridge/SETUP.md` for stopping and uninstalling the per-user service.

For a source checkout, run the bridge installer from the repository root with `zsh MacBridge/install.command`. The four `MacBridge/*.command` scripts in this web-uploaded source release do not have executable file permissions. To use the double-click instructions in `MacBridge/SETUP.md`, first run `chmod +x MacBridge/*.command` from the repository root.

## Distribution status and limitations

This source release is a reviewed staging copy, not a public repository yet. The separately notarized Mac companion is arm64-only; no fresh-Mac or Intel compatibility test is claimed. The iOS App Store build and notarized Mac binary were built from the MacLink worktree, but a reproducible source-to-binary build attestation for the iOS archive has not been produced. Source publication does not imply App Store approval or that an OpenAI service entitlement has been granted. Check the current [Codex app-server authentication documentation](https://learn.chatgpt.com/docs/app-server#auth-endpoints) and applicable service terms for your distribution mode.

MacLink source and generated icon artwork are released under `LICENSE`. External products and services are listed in `THIRD_PARTY_NOTICES.md` and keep their own terms. For support, see the project's [support page](https://foraihelp.com/maclink-support); the public companion download link must be added there only after the verified binary is actually hosted.
