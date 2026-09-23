# Phase 1 Open Questions and Review Gate

Phase 1 stops here. No vendoring, offline installer or upstream patch was created. The questions below materially determine Phase 2 size and licensing; recommended choices are included for review.

| # | Decision | Recommendation | Impact if changed |
|---:|---|---|---|
| 1 | First supported platform | **Approved by project direction: native Windows x64 (Windows 10/11), Python 3.11** | Windows ARM64, Linux and macOS remain separate later profiles because native wheels, binaries and validation differ. |
| 2 | Base product profile | **Approved by project direction: packaged Windows Electron desktop app plus its local Python backend, CLI and required web assets**; exclude general browser automation, voice/wake, local models and WhatsApp initially | Desktop packaging is mandatory, but unrelated optional features remain separate to keep the first closure reviewable. |
| 3 | Python install form | Approved source-layout editable install from pristine upstream with local locked deps | Upstream blocks wheel/sdist outside Nix. The alternative is to reproduce and export the Nix build closure. |
| 4 | Source import mechanism | Commit the pristine upstream tree without nested `.git`, pinned by `upstream.lock`; use patches externally | Keeping a submodule conflicts with a self-contained offline clone unless its objects/content are also bundled. |
| 5 | Node delivery | Prebuild the Windows Electron application and retain a verified npm cache for reproducible rebuild/maintenance | The distributable must not run npm or download Electron on the target machine. |
| 6 | Browser support | Make a separate opt-in profile with exact agent-browser + Playwright Chromium | Otherwise browser discovery must fail explicitly and never run npx/download. |
| 7 | Desktop application | **Approved by project direction: bundle and validate the Electron desktop application on native Windows x64** | Requires Electron 40.10.2, Windows native npm packages such as `node-pty`, NSIS/MSI packaging inputs, notices, and an offline-safe backend launch path. |
| 7a | Tauri bootstrap installer | Do not make it the Phase 2 runtime deliverable; revisit after its Rust closure is locked | It has no committed Cargo lock and is designed to drive the current networked `install.ps1`. The Phase 2 artifact can instead be a packaged Electron app plus the later Phase 3 offline installer. |
| 8 | Container distribution | Prefer a prebuilt OCI archive after core install works | A fully offline Docker build additionally needs base images, apt packages, SQLite/s6 sources and build toolchains. |
| 9 | Python extras | Approve an explicit list; default core should disable lazy installs | `all` is not actually every provider and still leaves many lazy features; indiscriminate vendoring is large. |
| 10 | Plugins/skills | Bundle only upstream-bundled content; external catalog installs are online maintenance/import operations | Catalog entries are code from separate repos even though plugin SHAs are pinned. |
| 11 | MCP/Honcho | External configuration only | Confirms the guardrail. The bundle contains clients/config examples, not servers/services or credentials. |
| 12 | Runtime meaning of “offline” | Installation and selected local features must work without public egress; cloud/provider features are unavailable unless explicitly connected | A general AI agent cannot use cloud model/provider APIs with total isolation. Define the smoke test around a configured local model or mocked provider. |
| 13 | Local model for smoke test | Use a user-supplied/local service endpoint first; do not bundle weights in the base | Bundling weights adds gigabytes and separate model licenses. |
| 14 | ffmpeg | Host prerequisite for the first profile | Redistributing a chosen build requires codec/license review. |
| 15 | WhatsApp bridge | Defer pending GPL-3.0 `libsignal` and LGPL libvips review | If included, separate it as an optional component with source/notice obligations. |
| 16 | GSAP in desktop/web graph | Legal review or exclude the consuming surface/artifact | npm reports a custom “Standard no charge” license. |
| 17 | CUA/computer-use | Disable until a fixed binary/source revision and license are approved | Current installer executes a mutable script from GitHub `main` and installs latest. |
| 18 | Telemetry/update checks | Off by default in offline profile | Users can opt in only when their deployment permits egress. |

## Technical blockers to resolve in Phase 2

1. Produce a Windows x64/Python 3.11-resolved artifact list from the 259-entry universal lock and verify a Windows wheel exists for every selected requirement.
2. Choose editable-vs-Nix project installation without altering upstream's packaging guard.
3. Pin exact Windows x64 uv, Python, Node/npm, ripgrep and any selected runtime binary; remove all “latest” acquisition.
4. Choose the npm offline-cache format and audit lifecycle scripts/native packages, including the Electron 40.10.2 archive, `node-pty`, Rolldown/esbuild bindings, electron-builder, NSIS/MSI tool payloads and icon/resource editing tools.
5. Resolve license metadata missing from Python locks and the npm exceptions in the license report.
6. Define configuration flags/environment that disable lazy installs, updates, hubs, model downloads, LSP installs, telemetry and browser fallback.
7. Define a clean native Windows x64 network-blocked test environment and a local/mock model smoke test.
8. Decide whether Phase 5 release installers will be unsigned development artifacts or Authenticode-signed. Signing credentials must remain external to Git and are not needed to prove offline behavior.
9. Validate packaged-app startup, Electron-to-Python backend launch, first-run setup, a mock/local chat, restart, and uninstall/cleanup with public egress blocked.

## Approved Phase 2 scope amendment

The first vendoring profile is `windows-x64-desktop`. A successful Phase 2 must collect and checksum every redistributable artifact needed to build the packaged Electron desktop application and its local Hermes backend without public network access. General-purpose Playwright/agent-browser automation is not implied merely because Electron embeds Chromium.

Phase 2 still produces vendored inputs and manifests, not the final user installer. Local-only installation and Windows end-to-end validation remain Phase 3 and Phase 4 work. The architecture must nevertheless avoid any Phase 2 choice that would require the target user's machine to download Electron, npm packages, Python packages, Python itself, Node, or packaging tools.

## Phase 1 acceptance checklist

- [x] Upstream repository cloned at an immutable commit and tree hash.
- [x] No upstream submodules and no upstream source modifications.
- [x] Python, Node, Rust, Nix, OS/binary, browser, source, container and CI dependency surfaces inventoried.
- [x] Install-time and runtime network paths inventoried.
- [x] Plugins, providers, Honcho and MCP integration surfaces inventoried.
- [x] License and redistribution concerns identified, including unresolved blockers.
- [x] Proposed distribution architecture documented.
- [x] Phase 2 has not started.
