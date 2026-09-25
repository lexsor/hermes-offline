# Offline installation — Windows x64 desktop

## Supported profile

Phase 3 supports native Windows 10/11 x64, the pinned CPython 3.11 runtime, and the packaged Electron desktop application. Linux, macOS, Windows ARM64, general browser automation, voice, messaging bridges, model weights, and external MCP/Honcho services are not included.

## Install

Open native Windows PowerShell in the repository and run:

```powershell
.\scripts\verify-deps.ps1
.\scripts\install-offline.ps1
.\scripts\verify-offline.ps1
```

The default destination is `%LOCALAPPDATA%\OfflineHermes`. Use `-InstallRoot C:\some\absolute\path` to select another location. An existing destination is not overwritten; `-Force` preserves it as a timestamped sibling backup before replacement.

The installer verifies every vendored byte before mutation, extracts the pinned runtimes, installs Python only from local wheels, primes an isolated npm cache only from local tarballs, runs the desktop workspace with `npm ci --offline --ignore-scripts --legacy-peer-deps`, materializes the reviewed native payloads, and builds an unpacked Electron application. Peer-only optional UI integrations are outside this profile. It never uses an online maintenance command.

Launch with `launch-hermes.cmd`; run the CLI with `hermes-offline.cmd`. Both launchers pin `HERMES_HOME` and force lazy dependency installation, pip indexes, and uv networking off.

## From a release archive

A release (`scripts\build-bundle.ps1`, Phase 5) is this repository's committed tree in a zip, plus `RELEASE-MANIFEST.json`, a generated `THIRD-PARTY-NOTICES.md` and `release-files.sha256`. Extract it with `tar.exe -xf` into a short path, then run `.\scripts\verify-release.ps1` before the steps above. When `RELEASE-MANIFEST.json` is present, `install-offline.ps1` checks the whole release tree (scripts, patches, upstream source) as well as the vendored artifacts, and records the release version in `install-state.json`. See [`RELEASE_NOTES.md`](../RELEASE_NOTES.md).

## Uninstall

`.\scripts\uninstall-offline.ps1` removes the install root and keeps the Hermes home. `-RemoveHermesHome` also removes the home, and `-RemoveBackups` removes the `-Force` backups and any leftover staging folders. `-WhatIf` lists what would be removed. It refuses a folder without a `windows-x64-desktop` `install-state.json`, refuses protected folders (drive roots, the user profile, `%LOCALAPPDATA%`, the repository), and refuses while any process runs from the install or the home. `%LOCALAPPDATA%\hermes` and `%APPDATA%\Hermes` are reported, never removed.

## Upstream patches

`upstream/hermes-agent` is kept byte-identical to the pinned commit. Where upstream behavior conflicts with offline operation and cannot be wrapped from outside, a reviewed patch in `patches/` is applied to the installer's **staged copy** of the source before anything is built. Each patch is listed with its SHA-256, target and reason in `manifests/patches.lock`. The installer checks each patch's hash and then runs `git apply --check` with the bundled Git. A patch that no longer applies (for example after an upstream refresh) stops the install with a message naming it.

| Patch | Why |
|---|---|
| `0001-desktop-no-remote-theme-fonts.patch` | The desktop's default theme injects a Google Fonts stylesheet on every start (the Phase 4 Azure run recorded the blocked DNS attempts from `Hermes.exe`). Remote theme fonts are no longer injected; every theme's font stack falls back to system fonts. |
| `0002-desktop-offline-profile-no-network-installer.patch` | Opening `app\Hermes.exe` directly used to bypass the launcher: the app ignored the offline home, wrote to `%LOCALAPPDATA%\hermes`, could attach to an online Hermes install, and offered *Install Hermes locally* / *Repair install*, which run upstream's networked installer. It also shared `%APPDATA%\Hermes` with any online Hermes Desktop. The desktop now applies the launcher's environment itself whenever `install-state.json` sits beside the app folder, keeps its Electron user data in `<offline home>\desktop-user-data`, skips the first-run install choice, makes *Repair install* a plain backend restart, and refuses the networked installer with an instruction to repair offline with `install-offline.ps1 -Force`. |

## Explicit limitations

The application still needs a configured inference provider. A loopback/LAN provider can be configured from the examples under `config/`; credentials remain user-owned and outside Git. Features excluded from the profile fail as unavailable rather than being downloaded.

Phase 3 verification checks the installed runtime and import surface. Blocking public networking and performing the full desktop smoke test are Phase 4 gates and are not claimed by these scripts.

## Failure behavior

- Missing or changed artifacts stop before installation and name the path.
- npm runs with `--offline`, audit/funding/update checks disabled, and lifecycle scripts globally suppressed.
- Python installs use `--no-index --no-deps --no-build-isolation` against the vendored wheel directory.
- A failed replacement restores the prior installation when `-Force` was used.
- No script downloads a missing dependency.
- For the whole install, every child process gets a network guard. `HTTP(S)_PROXY`, npm's proxy settings, and `ELECTRON_MIRROR` point at a closed loopback port, and the Electron and electron-builder caches are redirected to empty per-install directories. Any client that tries to download fails at once, and a host with a pre-populated `%LOCALAPPDATA%\electron\Cache` cannot hide a missing vendored artifact. This is defense in depth and does not replace the Phase 4 firewall test, because clients that ignore proxy variables are not stopped by it.
- The Electron runtime is materialized into the `electron` package that Node resolves from `apps/desktop`. The builder refuses to start if `electron.exe` is missing, instead of letting upstream's `run-electron-builder.mjs` fall back to `@electron/get`.
- The Python venv and all pip installs are created after the staging directory moves into place, so console-script launchers never embed a staging path. A failure after the move removes the partial install and restores any `-Force` backup.
