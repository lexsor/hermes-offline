# Phase 4: offline install test

**Result: pass.** On a clean Windows 11 x64 VM with public outbound networking blocked, Offline Hermes verified, installed, reinstalled, rolled back a failed replacement, and uninstalled from this repository alone, with no public network attempt by the installer or any tool it ran.

Record run: `phase4-20260924-180727` (run 3), 2026-09-24. Earlier runs are summarized under [History](#history-runs-1-and-2).

## Environment

| | |
|---|---|
| Host | Azure VM, `Microsoft Corporation` / `Virtual Machine`, Windows 11 Pro 10.0.26200, 4 vCPU / 16 GB |
| Shell | Windows PowerShell 5.1 only; PowerShell 7 is not installed or vendored |
| Access | Azure Bastion (Standard) native-client tunnel; RDP drive redirection used to export evidence |
| Source under test | Repository export of commit `6bf7702` (`vendor/`, `upstream/`, which are unchanged since), with `scripts/`, `tests/`, `patches/`, `manifests/`, `config/` and `docs/` synced to commit `a3c5f2a` before the run |
| Upstream | `NousResearch/hermes-agent` `bc655bf`, tree `8196c19`, plus patch 0001 applied to the staged copy at install |

## Network isolation

Two independent layers were active for the whole run:

1. **Azure NSG** outbound rule `phase4-deny-internet`: deny, service tag `Internet`, priority 100.
2. **In-guest firewall**, `tests/phase4/Enable-NetworkBlock.ps1`, enabled at 11:05:56 VM time:
   - default-deny outbound on all profiles;
   - 125 built-in outbound allow rules disabled;
   - an explicit block rule for every non-loopback address;
   - dropped-packet logging, and a 512 MB DNS client log.

   This layer also blocks Azure platform DNS (`168.63.129.16`), which the NSG does not.

`Assert-NetworkBlocked.ps1` ran at enable time, in P0, and at the very end. Every time, **0/16 public probes succeeded** (system DNS, direct DNS to 8.8.8.8 and 1.1.1.1, TCP 443 to PyPI, npm, GitHub and nousresearch.com, raw TCP over IPv4 and IPv6), and loopback worked.

## Clean host (P0)

`Get-CleanHostFindings` returned **no findings**:
- none of `python`, `node`, `npm`, `git`, `uv`, `rg` or `pip` on PATH;
- no `%LOCALAPPDATA%\electron`, `npm-cache`, `pip`, `uv` or `hermes`;
- no `HERMES_HOME` or package-manager variables;
- long paths enabled.

The VM was reset beforehand with `docs/phase-4-record-run.md` Stage A, which removed everything runs 1–2 had created.

## Results

| Case | Result | Evidence |
|---|---|---|
| T1 `verify-deps.ps1` | **Pass**: 1110/1110 files verified | `T1-verify-deps.log` |
| T4 clean offline install | **Pass**: 1509.7 s (25 min) | `T4-install.log` |
| T5 `verify-offline.ps1` | **Pass**; `hermes --version` cold start 0.6 s | `T5-verify-offline.log` |
| T10a reinstall with `-Force` | **Pass** | `manual/T10a-*.txt/log` |
| T10b failed replacement | **Pass** | `manual/T10b-*.txt/log` |
| T10c uninstall footprint | **Pass**, with documented residue | `manual/T10c-leftovers.txt` |

The checksum cases T2 and T3 are in [checksum-verification.md](checksum-verification.md).

**T4 in detail:**
- The vendored Electron runtime was used: the log shows `using custom unpacked Electron distribution`, and there are 0 download-fallback markers.
- `npm ci` added 1118 packages offline.
- Patch `0001-desktop-no-remote-theme-fonts` was applied to the staged source.
- The Hermes home was seeded.
- The new host-state check found **no host caches created** by the install.

**T10a in detail:**
- The previous install was preserved as `OfflineHermes.previous-20260924185945`.
- The patch was re-applied.
- The existing `config.yaml` was kept, with a **byte-identical hash**.
- `verify-offline` passed afterwards.

**T10b in detail:** a scratch copy of the installer, with one wheel corrupted, run with `-Force` over the real install:
- It **stopped with exit 1** and `ERROR: Checksum mismatch: vendor\python\windows-x64-cp311\annotated_doc-0.0.4-py3-none-any.whl`.
- It did so **before touching the existing install**: the backup count stayed 1/1, and `verify-offline` still passed.

**T10c in detail.** After removing the install root, its backups and the offline home, only these remained:

| Path | Why | Status |
|---|---|---|
| `%APPDATA%\Hermes` | Electron user data from the desktop cases | Expected; documented |
| `%LOCALAPPDATA%\hermes` | Created by the T8 direct launch (`desktop-plugins\`, `logs\desktop.log`) | Gap G1 in [final-gap-list.md](final-gap-list.md) |
| `%TEMP%\phase4-test-home` | The harness's mock-provider home | Test-only |

### Network attempts during install cases

From the firewall drop log and the DNS client log, with each event attributed to the process that held its PID at that moment. Both logs covered the whole run, and **every in-case event was attributed**.

| Case | Hermes / installer / tool processes | Unattributed | Host background (blocked) |
|---|---:|---:|---:|
| T1 | 0 | 0 | 13 |
| T4 | **0** | 0 | 4079 |
| T5 | 0 | 0 | 36 |
| T10a | **0** | 0 | 5197 |
| T10b | 0 | 0 | 97 |

"Host background" is Windows, Azure agents, Edge/WebView, OneDrive and Defender traffic. It was blocked, and none of it comes from Hermes.

## Deviations

- **Stage C (P0–T11) ran from an elevated window**, not as a standard user, as a consequence of how the session was opened. It used the same user profile, and P0 still ran in full. This doesn't affect the network or install results, but a standard-user run should be repeated before release (gap G8).
- The collector used during the run had an attribution bug for overlapping process logs, fixed in `7fb67c5`. Run 3 was **re-attributed offline** with the fixed logic from the exported CSVs; the raw events are unchanged.
- The Hyper-V stages of `New-Phase4Vm.ps1` were not used; this run used the Azure procedure (`docs/phase-4-azure-runbook.md`, `docs/phase-4-record-run.md`).

## History: runs 1 and 2

Two earlier runs on the same VM found the defects that run 3 confirms fixed:

| Run | Found | Fixed in |
|---|---|---|
| Phase 3 host run | Electron `@electron/get` fallback; shared online `HERMES_HOME` plus live update check; stale venv paths | `a3567b8` |
| 1 (`115257`) | Loopback firewall rule rejected by Windows; 1 MB DNS log wrapped, losing test-window DNS evidence; collector failures under 5.1 (`ConvertFrom-Json` arrays, locked `pfirewall.log`) | `ba64c2e`, `69d9ff0`, `0c585d9`, `291d6b5` |
| 2 (`143220`) | Install left `%LOCALAPPDATA%\npm-cache` (npm logs); interactive-5.1 architecture check failure; PID-reuse misattribution; desktop Google Fonts request; backend model-catalog / models.dev downloads | `6db0e3a`, `b499ea8`, `fd3a545`, `224f6f5` |

Raw evidence for all three runs is in `phase4-evidence/`. It is git-ignored and kept outside the repository history.
