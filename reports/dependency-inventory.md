# Dependency Inventory

## Scope and upstream pin

This inventory covers the detached, clean checkout at `upstream/hermes-agent/`, pinned by `manifests/upstream.lock` to commit `bc655bfb40ff7414bbec9dd179b17cf41e2f60ba` (tree `8196c19ca3510d2bd1297c41c72059742379780d`). No upstream source file was changed. Discovery was static; no install was run.

## Summary

| Class | Authoritative inputs | Observed surface | Offline implication |
|---|---|---:|---|
| Python | `pyproject.toml`, `uv.lock`, `constraints-termux.txt` | 37 core requirements, 46 extras, 259 locked distributions (258 registry + the editable project) | Vendor the chosen platform's complete wheel closure, plus build inputs for unavoidable sdists. Never resolve from PyPI during install. |
| Node | root/workspace and three standalone `package-lock.json` files | 1,421 root lock entries; Photon 111; WhatsApp 167; website 1,390 | Vendor npm tarballs or a verified immutable cache. Review lifecycle scripts and native/optional packages. |
| Rust | `apps/bootstrap-installer/src-tauri/Cargo.toml` | 18 runtime/build declarations; no committed `Cargo.lock` | Cannot claim a reproducible/offline Tauri build until a lock and crate closure exist. |
| Nix | `flake.nix`, `flake.lock`, `nix/*.nix` | 7 commit-pinned GitHub inputs plus nixpkgs-derived package closure | Nix store paths are not present; an offline Nix build needs a pre-populated closure or exported store. |
| OS/binaries | installers, Dockerfile, runtime probes | Python, Node/npm, Git, uv, ripgrep, ffmpeg and feature-specific tools | Pin per platform and record source, license, checksum, and ABI. |
| Browser | Playwright/Electron plus runtime browser helpers | Playwright 1.62.1, Electron 40.10.2; Chromium downloaded separately | Browser payloads are not in npm tarballs and need their own manifest. |
| Source/catalogs | plugin/MCP/skills catalogs and update paths | 223 plugin catalog YAMLs (222 real entries), 65 optional MCPs, 208 skill definitions | Bundled catalogs are data, but enabling/installing entries can fetch or execute external code/services. |
| Containers/CI | Dockerfile, two Compose files, 33 workflows | online apt, image pulls, npm/uv/Playwright and release downloads | Current container and CI paths are online build paths, not offline build inputs. |

## Python

The project is `hermes-agent==0.21.3`, MIT, requiring Python `>=3.11,<3.14`; `.python-version` selects 3.11. Upstream intentionally blocks wheel/sdist creation outside a Nix build in `setup.py`, so the distribution must use either an editable/source-layout install or an approved Nix build. It must not assume `pip wheel .` works.

Core direct requirements are:

`openai`, `certifi`, `python-dotenv`, `fire`, `httpx[socks]`, `rich`, `tenacity`, `pyyaml`, `ruamel.yaml`, `requests`, `jinja2`, `firecrawl-anydoc`, `pydantic`, `prompt_toolkit`, `croniter`, `snowballstemmer`, `packaging`, `Markdown`, `PyJWT[crypto]`, `urllib3`, `cryptography`, `tzdata` (Windows), `psutil`, `websockets`, `pathspec`, `fastapi`, `uvicorn`, `httptools`, `watchfiles`, `python-multipart`, `ptyprocess` (non-Windows), `pywinpty`/`pywin32`/`concurrent-log-handler` (Windows), `Pillow`, `pillow-heif`, and platform-gated `nemo-relay`.

Optional groups cover uvloop; Anthropic, Bedrock, Vertex, Azure Identity and Mistral providers; Exa, Firecrawl and Parallel search; FAL image generation; Edge/ElevenLabs/Mistral TTS; faster-whisper voice; wake-word engines; Modal/Daytona/Vercel terminals; Honcho/Hindsight/Supermemory/Mem0; Telegram, Discord, Slack, Matrix, Teams, WeCom, DingTalk, Feishu and Google Chat; Google APIs; Home Assistant; SMS; MCP/computer-use/ACP; OTLP; web/dev and Termux profiles. The exact groups and pins are in `pyproject.toml:188-405`.

`uv.lock` is version 1 revision 3 and includes hashes and URLs for 259 packages, but it does not record licenses. It represents all marker/extra variants, not a minimal supported-platform artifact set. Native and large packages include `cryptography`, `nemo-relay`, Pillow/HEIF, `httptools`, `uvloop`, `numpy`, `onnxruntime`, `ctranslate2`, `faster-whisper`, `sounddevice`, `sherpa-onnx`, `ai-edge-litert`, `pywinpty`, `pywin32`, `python-olm` and related platform wheels.

Runtime dependency mutation is built in. `tools/lazy_deps.py` has an allowlist of exact package specs and installs missing providers/features with uv/pip unless disabled. Plugin dependencies use the same installer ladder (`hermes_cli/plugin_python_deps.py`). Offline mode must set `HERMES_DISABLE_LAZY_INSTALLS=1` or the equivalent configuration and replace every enabled feature with preflighted local artifacts.

Additional Python requirements outside the main lock include `optional-skills/finance/dcf-model/requirements.txt` and CI-only direct `pip install` commands. These are not part of a minimum runtime closure unless their feature/profile is selected.

## Node and frontend/desktop

The root npm workspace requires Node `^22.22.0 || ^24.11.0 || >=26.0.0` and npm `<11.10.0 || >=11.17.0`; `.nvmrc` is 26. Workspaces are `apps/*`, `ui-tui`, `ui-tui/packages/*`, `web`, and `tests-js`.

| Project | Direct dependency shape | Lock |
|---|---:|---|
| Root workspaces | 6 dev dependencies; local workspace links | `package-lock.json` v3, 1,421 entries |
| Desktop | 76 runtime, 30 dev, 1 optional | root lock; includes Electron 40.10.2 and Playwright 1.62.1 |
| Bootstrap installer | 20 runtime, 6 dev | root lock plus Rust side |
| TUI / `@hermes/ink` | 8+20 runtime, 7+2 dev, 2 peers | root lock |
| Web | 23 runtime, 14 dev | root lock |
| Photon sidecar | 1 direct | standalone v3 lock, 111 entries |
| WhatsApp bridge | 4 direct | standalone v3 lock, 167 entries |
| Website | 9 runtime, 4 dev | standalone v3 lock, 1,390 entries; documentation build only |

All non-registry resolutions in the root lock are local workspaces. Registry tarballs use `registry.npmjs.org`. Native/optional packages include Electron binaries, `get-windows`, lightningcss platform packages, sharp/libvips, keytar-style/native Electron ecosystem packages, and platform-specific optional packages. Phase 2 must run lifecycle-script review before choosing `npm ci` behavior.

Runtime npm installs occur for source-built web/TUI/desktop, the WhatsApp bridge, LSP servers, browser helpers and configured stdio MCP commands using `npx`. Several LSP recipes are unpinned (`pyright`, `typescript-language-server`, Svelte/Astro/YAML/Bash/PHP/Dockerfile servers) and `gopls@latest`; these must be pinned or disabled in the offline profile.

## Rust, Nix, containers, and CI

The Tauri bootstrap installer declares Rust 1.77 and broad semver dependencies (`tauri = "2"`, Tokio 1, reqwest 0.12, etc.) without `Cargo.lock`. Treat its build as out of the first offline profile unless the missing lock is generated and reviewed.

`flake.lock` pins `nixpkgs`, `flake-parts`, Home Manager, uv2nix, pyproject-nix, build-system-pkgs and npm-lockfile-fix by commit and NAR hash. This is reproducible only when the referenced Nix closure is available.

The Dockerfile uses Debian 13.4, pinned uv and Node image digests, apt packages, pinned SQLite 3.53.4 and s6-overlay 3.2.3.0, then online npm, Playwright and uv operations. Compose builds or pulls `hermes-agent`; Windows Compose pulls `nousresearch/hermes-agent:latest`. CI uses GitHub-hosted runners, commit-pinned actions, apt/brew/winget-style prerequisites, registry installs, artifact services and Docker registries. None is an offline validation path as written.

## Plugins, providers, Honcho, and MCP

- The repository bundles 105 `plugin.yaml` manifests and 223 catalog YAMLs. All 222 actual catalog entries have a 40-character commit SHA and repo URL (221 GitHub, 1 GitLab). Catalog install clones that pin, then may install declared Python dependencies.
- The 65 optional MCP manifests are configuration entries only: 65 HTTP endpoints, 55 OAuth and 10 unauthenticated, with no bundled server and no local install block. This matches the requirement to treat MCP servers as external services.
- Honcho is `honcho-ai==2.2.0`, lazily installed, configured through `HONCHO_API_KEY` or `HONCHO_BASE_URL`, and persists config outside the checkout. It remains an external service; do not bundle it.
- Provider, messaging, search, image/video/audio, observability and model integrations are optional external network services. Their SDKs may be vendored, but credentials and service content must not be.

## Phase 2 dependency rule

The selected profile must produce a platform-resolved bill of materials. Every enabled dependency must map to one immutable local artifact and checksum. Everything else must be explicitly disabled or reported as an external/non-vendored exception. No package-manager resolver may have a public index configured in the offline path.

