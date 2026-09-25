# Offline Hermes release notes

## Release status: internal, not for public distribution

This release has **not** passed the public-release gates below. Share it only within the deployment it was built for until they are closed.

| Gate | State |
|---|---|
| Legal/compliance review of the redistributed artifacts (G11) | Open. See [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) (generated into the release archive) and [`reports/license-redistribution-review.md`](reports/license-redistribution-review.md). |
| Full review of the 107 key-like strings in `upstream/` (G16) | Open. |
| Standard (non-elevated) user validation run (G8) | Open. |
| Windows 10 validation (G14) | Open. Only Windows 11 is validated. |
| Upstream update workflow (Phase 6) | Not started. |

The exact build is recorded in `RELEASE-MANIFEST.json` at the top of the extracted archive: the release version, the source commit, the upstream Hermes commit and tree, the applied patches, and file counts.

## What this release is

A self-contained, offline-installable Windows x64 distribution of [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent) v0.21.3 (`bc655bf`): the CLI, the Python backend and the Electron desktop app. The archive holds the complete repository: the unmodified upstream source, two reviewed offline patches, 1,110 pinned and checksummed dependency artifacts, the installer, and the validation reports. The target machine builds the install from these files alone. Nothing is downloaded, and a missing or altered file stops the install with its name.

The archive is not a prebuilt install. Python virtual environments and their launchers record absolute paths, so the install is built on the target machine, at its final location. The install takes 12 to 20 minutes.

## Supported platforms

| Platform | Status |
|---|---|
| Windows 11 x64 (validated on Windows 11 Pro, build 26200) | Supported. Validated with outbound networking blocked (Phase 4). |
| Windows 10 x64 22H2 | Expected to work, not validated. |
| Windows ARM64, Linux, macOS | Not supported. The installer refuses to run on them. |
| Containers (Docker/OCI) | Not provided. See [Containers](#containers). |

Runtimes in the install: CPython 3.11.16, Node 26.9.0, Electron 40.10.2, PortableGit 2.54.0, ripgrep 15.2.0 and uv 0.9.28.

## Manual prerequisites

These are not in the archive and must be provided on or near the target machine:

1. **Windows PowerShell 5.1**, which ships with Windows. No other host software is needed: no Python, Node, Git or Visual Studio.
2. **`tar.exe`**, which ships with Windows 10 1803 and later. It is used to extract the archive.
3. **Disk space**: 0.6 GB for the archive, 0.7 GB extracted, and 1.7 GB for the finished install. The build also needs working space next to the install folder (the npm closure and the Electron build, removed afterwards). That peak was not measured, so allow at least 5 GB free on the install drive.
4. **An inference server** on loopback or the local network with an OpenAI-compatible API, for example vLLM, llama.cpp or Ollama, serving a model with a context window of at least 64K tokens. Model weights are not included.
5. **Optional external services**, such as Honcho or MCP servers, which you run and configure yourself. See `config/honcho.example.yaml` and `config/mcps.example.yaml`.
6. **Administrator rights are not needed.** The default install goes into `%LOCALAPPDATA%`.

## Transfer and verify

On the machine that received the release files:

```powershell
# 1. Check the archive against the published .sha256, which must come from a trusted channel.
Get-FileHash .\OfflineHermes-<version>-windows-x64-desktop.zip -Algorithm SHA256
Get-Content  .\OfflineHermes-<version>-windows-x64-desktop.zip.sha256

# 2. Extract with tar, into a short path such as C:\OfflineHermes-src.
#    File Explorer's "Extract all" is slow and can skip upstream files whose paths exceed 260 characters.
mkdir C:\OfflineHermes-src
tar.exe -xf .\OfflineHermes-<version>-windows-x64-desktop.zip -C C:\OfflineHermes-src
cd C:\OfflineHermes-src\OfflineHermes-<version>

# 3. Verify every file of the release, then every vendored artifact.
powershell -ExecutionPolicy Bypass -File .\scripts\verify-release.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify-deps.ps1
```

`verify-release` compares all files against `release-files.sha256`. It catches a partial or damaged extraction, but it does not prove who published the archive: that trust comes from the `.sha256` you checked in step 1. The installer runs both checks again before it changes anything.

## Install, configure, launch

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-offline.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\configure-provider.ps1 -BaseUrl http://<server>:8000/v1 -Model <model-id>
powershell -ExecutionPolicy Bypass -File .\scripts\verify-offline.ps1
```

Run `configure-provider` **before the first desktop launch**. Without a configured provider, the desktop opens on a setup screen whose options need the Internet (G18). Launch the desktop with `%LOCALAPPDATA%\OfflineHermes\launch-hermes.cmd`, or run the CLI with `hermes-offline.cmd`. Opening `app\Hermes.exe` directly is also safe.

| Location | Contents |
|---|---|
| `%LOCALAPPDATA%\OfflineHermes` | The install. Choose another with `-InstallRoot`. |
| `%LOCALAPPDATA%\OfflineHermes-home` | Your settings, history and desktop data (`HERMES_HOME`). Choose another with `-HermesHome`. A reinstall never overwrites it. |

The extracted release folder can be deleted after the install. Keep it, or the archive, if you want to repair or reinstall with `install-offline.ps1 -Force`.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-offline.ps1 -WhatIf   # show what would be removed
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-offline.ps1           # remove the install, keep your Hermes home
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-offline.ps1 -RemoveHermesHome -RemoveBackups
```

The uninstaller removes only a folder whose `install-state.json` identifies an Offline Hermes install, and it refuses while Offline Hermes is running. It never removes `%LOCALAPPDATA%\hermes` or `%APPDATA%\Hermes`, which may belong to an online Hermes install; it reports them if present.

## Known limitations and exceptions

The complete list with owner actions is [`reports/final-gap-list.md`](reports/final-gap-list.md), and every non-vendored item is in [`reports/redistribution-exceptions.md`](reports/redistribution-exceptions.md). In short:

- **Not included:** browser automation (Playwright/agent-browser), voice, messaging bridges, ffmpeg, model weights, Honcho and MCP servers. These features report as unavailable rather than downloading anything.
- **No model catalog offline** (G4): the desktop shows no per-provider model lists or registry metadata. Set the model name and `context_length` yourself.
- **First-launch setup screen** (G18): a desktop launched before `configure-provider` shows cloud-only setup choices, and their lookups are blocked.
- **On-demand remote content** (G12): web links, social-media embeds, the skills hub and the plugin catalog fail offline.
- **WPAD lookups** (G3): the desktop's network stack looks up the local name `wpad`, which on a corporate LAN can reach an internal proxy auto-configuration server.
- **Not exercised in validation** (G9): tool execution, a real model server and MCP servers.
- **Unsigned:** neither the archive nor the executables built on the target carry an Authenticode signature.

## Containers

No Dockerfile, Compose file or container image ships in this release. The only profile is the Windows x64 desktop, and a Linux image would need its own vendored closure of Linux wheels, Node and binaries, with its own license review and network-blocked validation. A Windows container could not run the desktop. Containers are left for a future `container-linux-x86_64` profile ([`reports/proposed-architecture.md`](reports/proposed-architecture.md)).

## Building a release (maintainers)

From a Git clone with LFS content (`git lfs pull`) and a clean, committed tree:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-bundle.ps1 [-ReleaseVersion 0.21.3-offline.1]
```

The script stages the committed files, verifies all vendored checksums (which also detects Git LFS pointer stubs), generates `RELEASE-MANIFEST.json`, `THIRD-PARTY-NOTICES.md` and `release-files.sha256`, then writes the archive, its `.sha256` and a copy of the manifest to `dist\`. It makes no network access. Publish the `.sha256` through a channel the recipients trust.
