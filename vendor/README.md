# Vendored Artifacts

This directory contains immutable inputs for the `windows-x64-desktop` profile. It does not contain an installed environment: `.venv`, `node_modules`, package-manager caches, and user configuration are intentionally excluded.

| Directory | Contents | Artifact count |
|---|---|---:|
| `python/windows-x64-cp311/` | Windows x64 CPython 3.11 wheels for the Hermes core closure and pinned build requirements | 68 |
| `node/windows-x64-desktop/tarballs/` | npm tarballs for the Electron desktop/shared workspace closure, including applicable Windows x64 native packages | 1,027 |
| `binaries/windows-x64/` | Python, Node/npm, PortableGit, ripgrep, uv, native lifecycle payloads, and Electron packaging toolsets | 10 |
| `browser/windows-x64/` | Electron 40.10.2 Windows x64 runtime | 1 |
| `source/windows-x64/` | Git for Windows and Lightning CSS corresponding source | 3 |

The Electron archive is the required desktop runtime. It does not enable the optional Hermes general browser-automation feature; Playwright and agent-browser browser payloads are not part of this profile.

The authoritative metadata is in `manifests/`. `checksums.sha256` covers every file under this directory. Phase 3 will materialize these artifacts using local-only installers and must fail if an artifact is absent or invalid. Nothing in this directory authorizes registry or release-site fallback.

Honcho, MCP servers, model/provider services, user models, and signing credentials remain external configuration or prerequisites.
