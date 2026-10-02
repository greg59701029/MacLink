# Source release verification (2026-10-01)

This directory is a staging copy for review. It has not been pushed to a public repository.

- The original project and isolated worktree copy are local directories on the owner's Mac. Neither location currently identifies an existing Git remote. Local work and unsigned/signed products outside this directory were left untouched.
- The staged `MacBridge` source and setup files match the resource sources inside the Apple-notarized `MacLink Companion.app` after extraction. The bundled `input-helper` and `screen-stream` are arm64 compiled binaries made from the two included Swift sources; binary reproducibility is not independently established. The notarized ZIP is separately retained with SHA-256 `bcff2ecf14bb65a736c34b0eada567a7e57b0ce3327720c17fa8f32965098a2c`.
- Both the staged iOS `Info.plist` and notarized Mac app report build number 3. The iOS source matches the current original source files, apart from an excluded backup text file. The staged iOS source has **not** been cryptographically matched to the uploaded build 3 IPA; a source-to-binary attestation remains to be prepared if required.
- The staging allowlist includes source, project configuration, app icons, docs, and source tests only. It excludes `DerivedData`, `build`, `Store` history, old release ZIPs, `xcuserdata`, Python bytecode, logs, test screenshots, provisioning material, TLS keys, pairing records, and local account state.
- Scanning the staged files found no private-key PEM header, credential assignment matching the test pattern, personal absolute home path, or likely email address. Source tests contain sample Tailscale-range addresses, not an observed user's current address. Static pattern checks cannot prove absence of every secret; review the final Git diff before publishing.
- Python 3.13: 45 MacBridge unit tests passed in a local loopback-capable environment. Swift checks: 89 private-address/HTTPS assertions and pairing-session cases passed. The sandbox alone blocked loopback binds and compiler module cache writes; reruns used a temporary module cache and local loopback. No formal MacLink service or pairing data was changed.

## Distribution and review boundaries

This MIT grant applies to the original MacLink source and generated icon art in this directory. External Tailscale, OpenSSL, Python, Apple frameworks, Codex, Jarvis/Ollama, and any separately installed model retain their own licenses and terms; they are not bundled here. Review their current terms before distributing any future bundled copies.

The official [Codex app-server authentication documentation](https://learn.chatgpt.com/docs/app-server#auth-endpoints) permits existing local/open-source app use and recommends Sign in with ChatGPT; MacLink currently uses the user's own Mac installation and own Codex account, without a developer relay or shared Codex credential in this source tree. That does not constitute a service entitlement guarantee for all users.

Apple [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 4.2.7 warrant close review because MacLink includes both generic desktop access and dedicated Codex/Jarvis task UI; the specific-software remote desktop conditions include user-owned hosts and local/LAN network behavior. Tailscale access from another network and Mac companion prerequisites need accurate review notes, and Apple may decide whether the rule applies. Guideline 5.2.2 requires rights to third-party service/content use; original source ownership alone does not settle user-generated desktop content or service rights. Apple review acceptance is not promised.

Before public Git publication: confirm the destination repository/owner, inspect the exact staged file list and diff, verify rights in the generated art and any copied material, then publish only this staging directory. No destination has been selected in this directory.
