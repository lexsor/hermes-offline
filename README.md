# Offline Hermes

A self-contained, offline-installable Windows x64 distribution of [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent): the CLI, the Python backend, and the Electron desktop app.

Every dependency needed to install it ships in this repository as a pinned, checksummed artifact. The installer uses only those artifacts. A missing or altered file stops the install with an error that names it, and nothing is ever downloaded as a fallback.

| | |
|---|---|
| Upstream | `NousResearch/hermes-agent` at `bc655bf` (Hermes Agent v0.21.3), stored unmodified; see [`manifests/upstream.lock`](manifests/upstream.lock). Two offline patches are applied at install time; see [`manifests/patches.lock`](manifests/patches.lock) |
| Profile | `windows-x64-desktop`: Windows 10/11 x64, CPython 3.11.16, Node 26.9.0, Electron 40.10.2 |
| Vendored | 1,110 checksummed files: 68 Python wheels, 1,027 npm tarballs, 10 runtime/tool binaries, the Electron runtime, 3 source archives |
| Host requirement | Windows PowerShell 5.1, which ships with Windows. Nothing else. |

## Status

| Phase | State |
|---|---|
| 1. Discovery | Done. Reports in [`reports/`](reports/) |
| 2. Vendoring | Done. Artifacts in `vendor/`, manifests in `manifests/` |
| 3. Offline installer | Done, and run on native Windows 11 x64 under both Windows PowerShell 5.1 and PowerShell 7. See [`reports/phase-3-native-windows-run.md`](reports/phase-3-native-windows-run.md) |
| 4. Network-blocked validation | Done on a clean Azure Windows 11 VM with outbound networking blocked: install, reinstall, rollback, CLI and desktop chats pass, with no public network attempt by Hermes. See [`reports/offline-install-test.md`](reports/offline-install-test.md), [`reports/offline-runtime-smoke-test.md`](reports/offline-runtime-smoke-test.md), [`reports/checksum-verification.md`](reports/checksum-verification.md) and the gaps in [`reports/final-gap-list.md`](reports/final-gap-list.md) |
| 5. Distribution | Not started |
| 6. Upstream maintenance | Not started |

Offline install and runtime are **validated for this profile** on Windows 11 x64 (Phase 4). Before any release: Phase 5 (distribution) and Phase 6 (upstream update workflow), plus the release-blocking gaps G7 and G11 in the gap list (G1/G2 are fixed pending a VM re-check).

## Getting the repository onto an offline machine

The vendored archives are stored with **Git LFS**. On a connected machine:

```powershell
git clone https://github.com/lexsor/hermes-offline.git
cd hermes-offline
git lfs pull
powershell -ExecutionPolicy Bypass -File .\scripts\verify-deps.ps1   # must report: Verified 1110 vendored files
```

If `verify-deps` reports checksum mismatches, the LFS content was not downloaded (the files are still pointer stubs). Run `git lfs pull` again.

Then copy the working tree to the offline machine. `.git` is not needed there. `tests\phase4\New-Phase4Vm.ps1 -Stage Export` produces a verified tar of exactly the files required.

## Install

From Windows PowerShell on the target machine, in the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-deps.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\install-offline.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\verify-offline.ps1
```

The install takes about 15–20 minutes. Most of that is the local Electron desktop build.

| Location | Contents |
|---|---|
| `%LOCALAPPDATA%\OfflineHermes` | The install: runtimes, venv, desktop app, launchers. Change it with `-InstallRoot`; `-Force` replaces an existing install, keeping a backup. |
| `%LOCALAPPDATA%\OfflineHermes-home` | Your Hermes settings and data (`HERMES_HOME`). Change it with `-HermesHome`. It is never overwritten by a reinstall and is kept separate from any online Hermes install. |

Launch with `launch-hermes.cmd` (desktop) or `hermes-offline.cmd` (CLI) from the install folder. Always use these launchers. They pin the offline Hermes home and runtimes, and keep lazy installs and update checks off.

Hermes still needs an inference provider. Point it at a local or LAN OpenAI-compatible server using the examples in [`config/`](config/); see [`docs/configuration.md`](docs/configuration.md). Options, failure behavior and profile limits are in [`docs/offline-install.md`](docs/offline-install.md).

## Not included

These are out of the first profile:

- Linux, macOS and Windows ARM64
- general browser automation (Playwright/agent-browser)
- voice
- messaging bridges
- model weights
- Honcho and MCP servers, which are configured as external services

Features outside the profile report as unavailable instead of being downloaded. Every non-vendored item is listed in [`reports/redistribution-exceptions.md`](reports/redistribution-exceptions.md).

## Known issues

- **Opening `app\Hermes.exe` directly** now behaves like `launch-hermes.cmd` (patch 0002): offline home, offline backend, and its own Electron user data, so it can run alongside an online Hermes Desktop. The in-app installer and *Repair install* never download; a broken install is repaired with `scripts\install-offline.ps1 -Force`.
- **`scripts\build-bundle.ps1`** zips an installed tree whose paths are fixed to a temporary folder, so the archive does not work anywhere else yet. A Phase 5 fix.
- **Redistribution:** a human legal review is required before public redistribution; see [`reports/license-redistribution-review.md`](reports/license-redistribution-review.md) and the policy in [`manifests/licenses.lock`](manifests/licenses.lock).

## Testing

```bash
bash tests/phase3/static-checks.sh    # installer invariants (needs ripgrep)
bash tests/phase4/static-checks.sh    # harness invariants and PowerShell 5.1 compatibility
```

For the Phase 4 network-blocked validation:

- On an **Azure VM**, follow [`docs/phase-4-azure-runbook.md`](docs/phase-4-azure-runbook.md).
- On **Hyper-V**, see [`tests/phase4/README.md`](tests/phase4/README.md), which uses `New-Phase4Vm.ps1`.
- The test cases and pass criteria are in [`docs/phase-4-validation-plan.md`](docs/phase-4-validation-plan.md).

## Repository layout

```
upstream/hermes-agent/  pristine upstream snapshot (tree hash pinned in manifests/upstream.lock)
patches/                reviewed offline-profile patches, applied to the staged source at install (manifests/patches.lock)
vendor/                 immutable artifacts: python/, node/, binaries/, browser/, source/ (Git LFS)
manifests/              per-kind locks, licenses.lock, checksums.sha256 (the install-time source of truth)
scripts/                verify-deps, install-offline, verify-offline, bootstrap, build-bundle (.ps1, plus .sh shims)
config/                 example Hermes, provider, Honcho and MCP configuration (no secrets)
docs/                   install, configuration, and Phase 4 plan and runbook
reports/                Phase 1 discovery, Phase 3 run results, and Phase 4 validation reports and gap list
tests/phase3/           installer static checks
tests/phase4/           network-blocked validation harness
```

The project's governing documents:

- [`AGENTS.md`](AGENTS.md): phases and guardrails
- [`REQUIREMENTS.md`](REQUIREMENTS.md)
- [`ARCHITECTURE.md`](ARCHITECTURE.md)
- [`ACCEPTANCE_TESTS.md`](ACCEPTANCE_TESTS.md)
- [`SECURITY.md`](SECURITY.md)
- [`REPOSITORY_STRUCTURE.md`](REPOSITORY_STRUCTURE.md)

## Definition of done

The project is complete only when a fresh supported machine can install and verify Hermes from this repository with outbound networking disabled, every non-vendored exception is documented with a reason, owner action and failure mode, and the upstream update workflow (Phase 6) exists and has been tested.
