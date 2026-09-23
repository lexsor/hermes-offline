# Redistribution Exceptions — Windows x64 Desktop Profile

## Scope and status

This is the Phase 2 exception register for `windows-x64-desktop`. The base profile contains the packaged Electron application's build/runtime inputs and the local Hermes Python backend inputs. It does not claim that an installer has been built or that the application has passed a network-blocked Windows run; those are Phase 3 and Phase 4 gates.

All 1,109 vendored artifacts are pinned and checksummed; the vendor README is also covered by the checksum file. `manifests/licenses.lock` contains one record per vendored artifact plus the pinned upstream source. No required artifact has an unknown declared license. A missing standalone license file inside a package archive is recorded explicitly in that lock and does not erase the package's declared license metadata. Human legal/compliance approval is still required before a public release.

## Required external items

| Item | Why it is not vendored | User-visible behavior required in later phases |
|---|---|---|
| Authenticode certificate, private key, timestamping credentials | Secrets and identity-bound signing material cannot be committed. | Release builds may be unsigned development artifacts until an external signing process is configured; signing failure must be explicit. |
| Model/provider endpoint and credentials | Hermes needs an inference provider; credentials are secrets and cloud availability is outside the distribution. | Configuration must accept a local or explicitly permitted remote endpoint. Missing configuration must report that no model provider is available. |
| Local model weights | Large, model-specific artifacts have separate licenses and hardware requirements. | The base profile must not download weights. A requested local model must be supplied and separately manifested. |
| ffmpeg | No reviewed Windows build/codec configuration was approved for the base profile. | Media features that require ffmpeg must fail with a named prerequisite; installation must not download it. |

## External configurable services

Honcho and MCP servers are deliberately external services under the project guardrails. The repository may provide endpoint configuration and health checks in later phases, but it does not redistribute or launch arbitrary server implementations. Provider APIs, databases, cloud browsers, messaging services, and other remote integrations follow the same rule. Their absence must disable the related capability or produce a clear configuration error, never trigger installation.

## Deferred optional profiles and surfaces

The following are outside this profile and have no vendored runtime closure:

- general browser automation, including agent-browser and Playwright Chromium payloads;
- voice, wake-word, speech-to-text, and text-to-speech extras;
- WhatsApp and other messaging bridges;
- CUA/computer-use binaries and remote installers;
- external plugin/skill catalog repositories;
- local model-serving stacks and model weights;
- containers, Nix closures, Linux, macOS, and Windows ARM64;
- the Tauri bootstrap application and WebView2 bootstrap payloads.

Requesting one of these capabilities in the base profile must not invoke `npx`, `pip`, `uv`, GitHub, a package registry, a model hub, or a browser download endpoint. A later approved profile needs its own immutable closure, license review, and checksums.

## License and notice conditions

These are obligations to carry into release assembly, not silent omissions:

- PortableGit is GPL-2.0-only with bundled components. The corresponding Git for Windows source archive is included under `vendor/source/windows-x64/`; materialized component notices and source-offer information must ship with the release.
- Electron must retain `LICENSE` and `LICENSES.chromium.html` from its archive.
- Node, CPython, npm, PortableGit, and the electron-builder toolsets are compound distributions. Phase 3 extraction must preserve their embedded license and notice files; Phase 5 must aggregate them into release notices.
- CC-BY-4.0 npm content requires attribution. MPL-2.0-covered content requires notices and the applicable source availability. Pure-Python wheels retain their modifiable source, npm source tarballs are retained, and exact Lightning CSS 1.32.0/1.33.0 upstream source tags are included for the native Rust artifacts.
- Forty-one Python/npm package archives declare licenses in package metadata but do not contain a filename recognized as a standalone license/notice file. They are itemized in `manifests/licenses.lock`; public-release review must confirm attribution text from the authoritative upstream package sources.
- The electron-builder NSIS, NSIS-resources, WiX, and 7zip toolsets retain their own embedded license/COPYING terms. They are build inputs, not claims that every tool is part of the installed application.

GSAP is not present in the selected desktop closure, so its custom license is not redistributed by this profile. `khroma@2.1.0`, which lacked lockfile license metadata, was inspected in its tarball and classified as MIT.

## Provenance and release caveats

The vendored artifacts were acquired from the source URLs recorded in their class manifests. npm tarballs were checked against the upstream package-lock SRI values, and Electron was checked against its official release checksum. `manifests/checksums.sha256` is the repository-level integrity authority for all vendored bytes.

Phase 2 does not include an offline installer, final application package, code signing, a Windows VM smoke test, or outbound-network enforcement. Those omissions are phase boundaries, not permission for later installers to download missing content.
