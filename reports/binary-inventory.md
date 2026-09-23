# Binary and System Dependency Inventory

## Baseline

The approved first target is native Windows x64 (Windows 10/11) with Python 3.11, an exact Node 26/npm build toolchain, and the packaged Electron desktop application. Linux and Windows ARM64 require separate later profiles.

| Binary/system item | Where used | Current acquisition/version | Phase 2 treatment |
|---|---|---|---|
| Python | Core runtime | `>=3.11,<3.14`; installers request 3.11 through uv/system | Prefer host Python 3.11 for the first bundle, or vendor a relocatable interpreter after license/ABI review. Never let uv download it offline. |
| uv/uvx | bootstrap, locks, installs | shell installer fetches mutable Astral script; Docker copies uv 0.11.6 from a digest-pinned image | Vendor a fixed per-platform uv release or remove it from offline runtime after environment creation. |
| Node/npm/npx | web, TUI, desktop, browser/MCP/LSP | `.nvmrc` 26; POSIX dynamically resolves latest v26 (then 24/22); Windows requests v22; Docker uses digest-pinned Node 26; npm constraints require modern npm | Pin exact Node and npm artifacts. Do not use `latest-vN.x`. |
| Git | import/update/plugins/skills/worktrees | host/system packages; Windows installer has a pinned PortableGit release path | Required for maintenance and some runtime features, not necessarily minimum startup. Pin if bundled. |
| ripgrep (`rg`) | fast repository/file search | apt/brew/winget or CI release tarball; no bundle artifact yet | Vendor fixed x86_64 binary and license, or make it an explicit host prerequisite. |
| ffmpeg/ffprobe | media, messaging, voice/video skills | apt/winget/choco/system | Version and codec licenses vary. Prefer documented host prerequisite until redistribution configuration is reviewed. |
| Chromium/Chrome | browser automation and tests | Playwright download or detected system browser | Separate browser manifest; see browser report. |
| Electron | desktop | npm package 40.10.2 downloads platform binary during install | Required Windows x64 runtime artifact; vendor the exact archive, checksum and notices, then package it before delivery. |
| s6-overlay | container supervision | 3.2.3.0, x86_64/aarch64/noarch/symlink archives with SHA-256 | Already well pinned; vendor only for offline container build. |
| SQLite | container WAL fix | source 3.53.4 (`3530400`) with SHA-256 | Vendor source plus build toolchain for container profile. |
| `cua-driver` | computer-use | mutable installer script from `trycua/cua/main`, which selects latest release | Blocker: pin binary/version/checksum/license or disable computer-use. |
| `agent-browser` | browser tool | lazily resolved with unversioned `npx agent-browser` | Pin package and closure or disable local browser. |
| Camofox | alternative browser | `@askjo/camofox-browser@^1.5.2` | Range is not an immutable artifact. Pin exact package or treat local Camofox as external service. |
| Lightpanda | alternative browser | detected external executable/service | External configurable service/binary; not in base bundle. |
| iron-proxy | sandbox egress proxy | GitHub release downloader in `agent/proxy_sources/iron_proxy.py` (code expects v0.39.0 schema) | Pin per-platform release and license if egress feature is included. |
| `bws` | Bitwarden Secrets Manager | GitHub release downloader in `agent/secret_sources/bitwarden.py` | Optional external credential tool; do not bundle secrets. Pin only if feature is approved. |
| Docker/Podman | terminal environment backend | host CLI/daemon; Docker image includes `docker-cli` | External host service. Do not vendor daemon in initial bundle. |
| `gh` | GitHub webhooks/auth/skills | PATH probe | Optional external tool. |
| systemd tools | gateway lifecycle | `systemctl`, `systemd-run`, `loginctl`; POSIX helpers include `bash`, `ps`, `setsid`, `timeout` | Document host requirements/fallbacks; do not assume systemd in containers. |
| media/audio native libs | Matrix/voice/native wheels | `libolm`, libffi, libatomic, PortAudio/device stack, bundled native wheel libs | Resolve per selected extras and platform. |

## Feature-specific developer/tool binaries

The LSP subsystem can auto-install pyright, TypeScript/Vue/Svelte/Astro/YAML/Bash/PHP/Dockerfile servers and `gopls@latest`; Rust Analyzer, clangd, LuaLS, Laravel LSP and PowerShell are manual. Optional skills reference ast-grep, nmap, whatweb, age, LaTeX, ComfyUI and many domain tools. These are not base dependencies merely because a skill mentions them. Each selected feature needs its own pin or a named external prerequisite.

## Container build packages

The Dockerfile installs `ca-certificates`, `curl`, `iputils-ping`, Python 3 and venv/dev headers, `ripgrep`, `ffmpeg`, `gcc`, `g++`, `make`, `cmake`, `libffi-dev`, `libolm-dev`, `libatomic1`, `procps`, `git`, `openssh-client`, `docker-cli`, and `xz-utils`. Apt metadata and `.deb` files are not vendored, so the image cannot currently build offline.

## Rules for the binary manifest

Every bundled binary must record semantic version, platform/architecture/libc, upstream URL, local path, SHA-256, license/notices, signature verification (if available), runtime purpose and install destination. Dynamic “latest,” package-manager names without versions, and remote install scripts are prohibited in the offline path.
