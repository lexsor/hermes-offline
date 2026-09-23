# Proposed Offline Distribution Architecture

## Decision summary

Use a profile-driven vendored distribution, not a fork that runs upstream's online installers. Keep the exact upstream tree recognizable under `upstream/hermes-agent/`, keep unavoidable changes as reviewable patches, and put all dependency artifacts, policy and validation outside that tree.

Approved first supported profile: native Windows x64 (Windows 10/11), Python 3.11, an exact Node 26/npm toolchain, and the packaged Electron desktop application with its local Hermes Python backend. CLI and required web assets are included because the desktop depends on them. General browser automation, voice/wake, WhatsApp, container build, Nix build and local model packs remain additive profiles.

## Repository layout

```text
upstream/hermes-agent/          pinned pristine source snapshot
patches/                        documented, ordered patches only if unavoidable
profiles/                       explicit feature/platform selections
vendor/
  python/<profile>/             wheels and reviewed sdists/build inputs
  node/<profile>/               npm tarballs or immutable offline cache
  binaries/<platform>/          uv/node/rg and approved optional binaries
  browser/<platform>/           Playwright browser and optional Electron archives
  source/                       crates, source archives, Nix exports, required source offers
  containers/                   optional OCI image/base-image archives
  models/                       optional, separately licensed model packs
manifests/                      upstream, Python, Node, binary, browser, source, license, checksum locks
config/                         examples and offline-safe defaults; never credentials
scripts/                        offline install/verify and separately named online maintenance
tests/                          missing-artifact, checksum, network-block and smoke tests
reports/                        discovery, exceptions and validation evidence
docs/                           install, configuration, external services and updates
```

Before committing the distribution, convert the Phase 1 detached clone into a source import without nested `.git` metadata while preserving the locked tree hash, or adopt a subtree workflow. Do not use an online-required submodule.

## Profiles

Each profile is a declarative allowlist of Python extras, npm workspaces/build outputs, binaries, browser payloads and external capabilities. Suggested profiles:

- `windows-x64-desktop`: packaged Electron desktop, local Python backend, CLI and required web assets; no public-network fallback or target-machine build.
- `windows-arm64-desktop`: later separate profile; do not claim support from x64-on-ARM emulation alone.
- `linux-x86_64-core`: later agent CLI/runtime, TUI and prebuilt dashboard profile.
- `linux-x86_64-browser`: core plus pinned agent-browser/Playwright Chromium.
- `linux-x86_64-messaging`: selected gateway adapters; WhatsApp remains separate pending GPL/LGPL review.
- `linux-x86_64-voice`: faster-whisper/audio closure and explicitly licensed model pack.
- `container-linux-x86_64`: prebuilt OCI archive or fully vendored build inputs.
- Later platform profiles for Linux, macOS and additional architectures.

Features absent from a profile must fail as “not included in this bundle,” not invoke a package manager.

## Build/install split

Online maintenance is the only place allowed to fetch. It resolves the selected profile, downloads immutable artifacts, captures licenses, verifies upstream signatures/hashes where available, generates manifests and builds frontend bundles. Offline install verifies `checksums.sha256`, checks platform compatibility, creates a local environment and installs strictly from `vendor/`.

The upstream project cannot normally build a wheel/sdist, so the first implementation should use a source-layout editable install with local Windows dependencies and prebuilt desktop output. The packaged Electron app must launch that managed local Python environment without invoking npm, uv downloads or the network. Do not bypass `setup.py`'s guard with an undocumented environment variable.

## Offline enforcement

- Python: `uv/pip --no-index` with explicit local paths, disabled Python downloads and `HERMES_DISABLE_LAZY_INSTALLS=1`.
- Node: locked install from a verified offline cache/tarball mapping; disable audit, update notifier and lifecycle scripts unless individually approved. Prebuild dashboard/TUI where practical.
- Windows desktop: vendor Electron 40.10.2 and all Windows x64 native npm packages and packaging payloads; produce the packaged app on a controlled Windows build host. The target machine receives build output and must not download Electron or rebuild native modules.
- Browser: extract a checksummed fixed revision and set its cache/executable path. No Playwright CDN.
- Runtime: disable update checks, Skills Hub fetch, plugin clone/install, model auto-download, LSP auto-install and telemetry in the default offline configuration.
- Containers: load OCI archives locally or build from local base image/artifact contexts only.
- Validation: block public DNS/TCP, observe attempted connects, then install and smoke-test. Local loopback and explicitly configured LAN services may be allowlisted by the test profile.

## Windows desktop distribution boundary

The Phase 2 closure must cover the Electron app's Windows x64 runtime and build-time inputs separately. Runtime inputs include the packaged Electron/Chromium files, application ASAR/resources, native `.node` modules, the managed Python 3.11 environment and local Hermes source. Build-only inputs include the exact Node/npm distribution, immutable npm cache, electron-builder and the NSIS/MSI/rcedit-related payloads it invokes.

The preferred first output is a fully unpacked, checksummed Windows application directory because it proves the runtime closure without conflating it with signing or installer behavior. NSIS and/or MSI release packaging follows after that closure is reproducible. Authenticode signing is recommended for user distribution but credentials and signing operations remain external; an unsigned internal validation build is acceptable for Phase 4 if its status is explicit.

The upstream Tauri bootstrap application is not the same as the Electron desktop runtime. It currently has no committed Cargo lock and drives network-oriented install scripts, so it is not required for the first desktop closure. If later included, its Rust crates, WebView2 bootstrapper and installer behavior need their own locked, checksummed source and binary manifests.

## External services

Honcho, MCP servers, model servers, Home Assistant, databases, Docker/Podman and provider APIs remain external. Provide example endpoint configuration and bounded health checks. An unavailable service must not trigger installation. MCP stdio commands must resolve to existing local executables; uncached `npx`/`uvx` is forbidden.

## Integrity and failure model

Manifests are human-readable and enumerate artifact ID, version/revision, profile, platform tags, upstream URL, local path, SHA-256, license, purpose and consumer. The installer verifies manifests and checksums before mutation. Errors name the missing/mismatched artifact, expected path, manifest and online maintenance command used to refresh it.

## Upstream preservation/update flow

`manifests/upstream.lock` is authoritative. Later, `update-upstream.sh` imports a requested commit into a staging tree, verifies the tree, reapplies `patches/series`, and generates dependency/network/license diffs. Refreshing artifacts is a separate online-only command. Acceptance requires a reviewed diff and a fresh network-blocked validation, not merely a successful online build.
