# Third-party software and services

This source release contains MacLink's Swift and Python source and generated app icon artwork. The iOS Xcode target declares no external Swift Package products. The bundled Mac helper executables are compiled from `MacBridge/input_helper.swift` and `MacBridge/screen_stream.swift`; their source is included here. The notarized binary ZIP is distributed separately and is **not** part of this source tree.

MacLink uses platform frameworks supplied by Apple. It also works with software the user installs separately: Tailscale for private networking, Python 3.10+, an OpenSSL executable supporting `req -addext`, and, for optional features, a compatible local Jarvis/Ollama runtime and the official Codex app/CLI. None of those third-party binaries, model weights, account credentials, or SDKs are included in this source release. Their separate licenses and terms apply to their installation and use. MacLink's MIT license does not license those external products or OpenAI services.

No analytics or advertising SDK was found in the iOS target. If future releases add third-party code or assets, their notices and license compatibility must be checked before distribution.
