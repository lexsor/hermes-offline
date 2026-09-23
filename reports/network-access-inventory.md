# Network Access Inventory

## Boundary

This report distinguishes dependency/bootstrap traffic (which must be eliminated from the offline install/runtime profile) from deliberately configured application traffic to providers or external local services. Static discovery covered shell/PowerShell installers, Python/TypeScript runtime code, Docker/Nix, CI, plugins, providers, skills, models, Honcho and MCP.

## Install and bootstrap traffic

| Path | Network behavior | Offline disposition |
|---|---|---|
| `scripts/install.sh`, `setup-hermes.sh` | Downloads the uv installer; uses uv/pip; dynamically resolves Node from `nodejs.org`; clones/fetches Hermes; installs OS packages; runs npm; downloads Playwright Chromium; optionally executes CUA installer from GitHub `main`. | Do not use as the offline entrypoint. Wrap/replace with local-only bootstrap. |
| `scripts/install.ps1` | Same classes plus Git for Windows, portable Node/winget/choco, repository ZIP, Electron mirror, Playwright, Camofox and CUA download-and-execute. | The approved Windows desktop profile must not execute these online acquisition paths. Phase 2 must supply fixed local artifacts; Phase 3 needs a separate local-only installer path. |
| `Dockerfile` | Pulls three base images; apt repositories; SQLite and s6 release archives; npm registry; Playwright CDN; PyPI. | Create an offline build context/base-image import path or distribute a prebuilt image archive. |
| Nix | Fetches locked GitHub flake inputs, nixpkgs sources and binary cache/store paths. | Export a complete closure; `flake.lock` alone is insufficient. |
| npm/uv/pip/cargo | Registry resolution and artifact download. `npm --prefer-offline` still falls back online. | Force local registries/cache paths and offline flags; block egress and fail on cache miss. |
| CI | GitHub Actions, apt, PyPI/npm, Docker registries, artifact/cache APIs, deployment hooks. | CI is an online maintenance surface; add a separate network-blocked validation job later. |

Notable mutable/unpinned download points are `https://astral.sh/uv/install.*`, `nodejs.org/dist/latest-vN.x`, CUA scripts from `trycua/cua/main`, `npx agent-browser`, `gopls@latest`, unversioned LSP npm recipes and Compose `:latest` images.

## Runtime dependency and code acquisition

| Surface | Trigger and destination | Risk / required control |
|---|---|---|
| Python lazy dependencies | First use of optional providers/features in `tools/lazy_deps.py`; plugin enable/install in `plugin_python_deps.py` | Disable online lazy installs. Pre-vendor selected extras and emit a named missing-artifact error. |
| Web/TUI/desktop/WhatsApp builds | Missing or changed `node_modules`/build output invokes npm from CLI/update/start paths | Ship built output or local npm closure; never run an online repair in offline mode. |
| Browser tool | `npx agent-browser`; Playwright/agent-browser Chromium installer; optional Camofox package | Preinstall fixed tool/browser revisions or disable browser locally with a clear diagnostic. |
| LSP | First use can npm/pnpm/yarn install servers or `go install gopls@latest` | Pin and vendor per server, or set LSP install strategy to manual/off. |
| Skills Hub | Fetches arbitrary well-known/URL skill bundles, LobeHub (`chat-agents.lobehub.com`), browse.sh and GitHub content/API | Disable hub browsing/install/update offline; bundled skills remain usable. |
| Plugin catalog/packs | Clones commit-pinned GitHub/GitLab repositories and installs safe PyPI-name dependencies | External plugins are not in the base bundle. Offline install must accept only locally imported, checksummed plugin bundles. |
| Updates | `git fetch`, repository ZIP downloads, dependency refresh, Electron rebuilds and desktop update checks | Disable automatic checks/updates in offline profile. Keep online-only maintenance commands separate. |
| Models | Hugging Face GGUF downloads, faster-whisper cache miss, openWakeWord download, sherpa KWS release archive, local-engine package downloads | Models/weights need separate manifests and license review. A cache miss must fail, not download. |
| CUA/egress/secrets | CUA installer from GitHub; iron-proxy and Bitwarden Secrets Manager binary release downloads | Exclude by default or vendor pinned signed/checksummed binaries. |
| User/skill commands | Terminal and bundled/optional skills can intentionally use curl/git/package managers | Offline validation must test the product install/start path, not promise that arbitrary agent-executed user commands are network-free. Document tool egress policy separately. |

## Runtime service traffic

These are functional integrations, not dependencies. They may be used only when explicitly configured and reachable under the deployment's network policy.

- Model/provider APIs: Nous, OpenAI, Anthropic, OpenRouter, xAI, Google/Vertex/Gemini, Azure, Bedrock, Mistral, Groq, DeepSeek, Moonshot/Kimi, Fireworks, Together, NVIDIA and other catalog providers.
- Search/content: Exa, Firecrawl, Parallel, Tavily, Brave, Perplexity, Keenable and SearXNG/custom URLs.
- Media: FAL, ElevenLabs, MiniMax, xAI, Mistral and OpenAI-compatible image/video/audio endpoints.
- Messaging/platforms: Telegram, Discord, Slack, Matrix, Teams/Microsoft Graph, Google Chat/PubSub, WhatsApp, Twilio, WeCom/Weixin, DingTalk, Feishu, Signal/BlueBubbles and plugin-defined services.
- Memory: Honcho (`HONCHO_BASE_URL` supports a local deployment), Hindsight, Supermemory, Mem0 and plugin-defined providers.
- Observability/webhooks: opt-in shared metrics/OTLP, trace upload, outbound webhooks and configured gateway delivery.
- Local services: Ollama, LM Studio, SearXNG, Home Assistant, Docker/Podman backends, local MCP HTTP/SSE and browser/CDP endpoints.

Provider traffic needs credentials from runtime environment/config only. No credential or generated auth store belongs in Git.

## MCP

The bundled optional MCP catalog contains 65 HTTP entries: 55 use OAuth and 10 require no auth. Sixty-four point at remote vendor services or a user-supplied URL; `unreal-engine` defaults to `http://127.0.0.1:8000/mcp`. Hermes also accepts user-defined stdio, Streamable HTTP and SSE servers. A stdio command such as `npx`/`uvx` can download on cache miss even though the transport itself is local.

Offline policy:

1. Do not bundle or auto-start third-party MCP servers in the base distribution.
2. Allow explicit local endpoint/command configuration.
3. Refuse uncached `npx`, `uvx`, `pipx`, Git clone or bootstrap activity while offline.
4. Health-check only the configured endpoint and distinguish “external service unavailable” from “missing local artifact.”

## Controls required later

- Set Python installers to `--no-index` plus a repository-local wheelhouse; disable uv Python downloads and lazy installs.
- Use `npm ci --offline` (or an approved immutable cache/tarball mapping) with audit/fund/update-notifier disabled; treat a cache miss as fatal.
- Set Playwright's download connection to a local artifact or extract a checksummed browser bundle; never let the manager contact its CDN.
- Disable update checks, skill/plugin discovery, model auto-downloads and telemetry in the base offline config.
- Run Phase 4 inside a network namespace/container firewall with DNS and public TCP blocked, and monitor attempted connects. A successful install alone is not proof of zero attempts.
