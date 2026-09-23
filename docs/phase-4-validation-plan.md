# Phase 4 plan: network-blocked validation

Status: harness built (`tests/phase4/`, see its README), including `New-Phase4Vm.ps1` for building the Hyper-V VM. Dry run on a connected, non-clean host passes P0 (expect-open), T1, T2, T3, T5, T6 and T11 under both Windows PowerShell 5.1 and PowerShell 7. The offline install also passes under 5.1. The firewall scripts and the Hyper-V stages of `New-Phase4Vm.ps1` were not executed on that host, by design; only its `Export` stage was. The network-blocked VM run has not started. Baseline: commit `a3567b8` (Phase 3 passing on a connected Windows 11 host; see `reports/phase-3-native-windows-run.md`).

Resolved during harness development: T6's mock provider config works with both `providers.<name>.api` and `providers.<name>.base_url`, so `config/hermes.example.yaml` needs no change. The CLI honors `OFFLINE_HERMES_HOME` through the launcher.

New risk found: on a host where a user-level `HERMES_HOME` is set (as on the development host), `Hermes.exe` opened directly (T8) would attach to *that* home's install rather than the offline one. The launcher always overrides it.

## Goal

Prove that a clean Windows 10/11 x64 machine, with public outbound networking blocked by the test harness, can verify, install and run Offline Hermes (CLI and desktop) from this repository alone. Every download attempt must fail visibly and be recorded.

Phase 4 is done when these four reports exist and every exit criterion below is met:

- `reports/offline-install-test.md`
- `reports/offline-runtime-smoke-test.md`
- `reports/checksum-verification.md`
- `reports/final-gap-list.md`

## Exit criteria

1. Public DNS and HTTP(S) to PyPI, npm, GitHub and nousresearch.com fail on the test VM for the whole run (the block is tested before and after).
2. `verify-deps.ps1`, `install-offline.ps1` and `verify-offline.ps1` pass on a clean VM snapshot.
3. The CLI and desktop smoke tests (T6, T7) complete a chat against a loopback mock provider.
4. The firewall drop log and DNS client log show **no** attempts to reach public hosts during T1–T7. Any attempt is either fixed or recorded as a gap with an owner.
5. The missing-artifact and checksum-failure tests (T2, T3) fail with the exact path and manifest, and make no network attempt.
6. The secret-hygiene scan (T11) finds only example placeholders.

## 1. Test environment

**VM:** Hyper-V generation 2, Windows 11 x64 (or 10 22H2) evaluation image, 4 vCPU, 16 GB RAM, 120 GB disk. Fully patched, **before** any Hermes content arrives.

**Clean means:** no Python, Node, Git, uv or ripgrep installed; no `%LOCALAPPDATA%\electron`, `%LOCALAPPDATA%\electron-builder`, `%LOCALAPPDATA%\npm-cache`, `%LOCALAPPDATA%\pip` or `%LOCALAPPDATA%\hermes`; no `HERMES_HOME` in the user or machine environment. The Phase 3 run showed why: a pre-populated Electron cache hid a network fallback. Preflight script P0 asserts all of this.

**Snapshots:**
- `S0-clean`: patched OS, long paths enabled (`LongPathsEnabled=1`), nothing else.
- `S1-staged`: S0 plus the repository copied in, network already blocked.
- Every test run starts from `S1-staged`.

**Getting the repository onto the VM:**
1. On a connected machine: `git clone` with LFS, then `git lfs pull`, then `scripts/verify-deps.ps1`. Every one of the 1110 files must match; this fails on LFS pointer files.
2. Copy the working tree, without `.git`, to a VHDX. Attach the VHDX to the VM and copy it to `C:\OfflineHermes-src`. This also tests that the tree works without Git metadata or LFS.
3. Record the source commit and the VHDX SHA-256 in `reports/offline-install-test.md`.

## 2. Network-block harness

Build `tests/phase4/Enable-NetworkBlock.ps1` (run as administrator on the VM only). It must:

- Set every firewall profile to `DefaultOutboundAction Block`, and allow only loopback (`127.0.0.0/8`, `::1`).
- Enable dropped-packet logging (`pfirewall.log`, max size) and the `Microsoft-Windows-DNS-Client/Operational` event log. Clear both.
- Remove the default gateway and DNS servers from the VM adapter, as a second layer. For the strictest runs, also switch the VM to a Hyper-V *Private* switch.

`tests/phase4/Assert-NetworkBlocked.ps1` runs before and after every test run, and fails the run unless all of these fail:

- `Resolve-DnsName pypi.org`
- `Resolve-DnsName registry.npmjs.org`
- `Invoke-WebRequest https://github.com -TimeoutSec 5`
- `Invoke-WebRequest https://1.1.1.1 -TimeoutSec 5`, which checks direct IP with no DNS
- a TCP connect to `140.82.112.3:443`

`tests/phase4/Collect-NetworkEvidence.ps1` copies `pfirewall.log` and the DNS client events to `reports/evidence/<run-id>/`. It then summarizes non-loopback drops by process and destination, and DNS queries for public names. **Every non-loopback drop or public-name lookup during T1–T7 is a finding.**

## 3. Test cases

Run in order from `S1-staged` as a standard (non-admin) user, except the harness scripts. Each case records its command, exit code, duration and full transcript under `reports/evidence/<run-id>/`.

| ID | Case | Pass criteria |
|---|---|---|
| P0 | Preflight | Clean-host checks above pass, and the network is blocked (Assert-NetworkBlocked) |
| T1 | `verify-deps.ps1` | 1110/1110 verified |
| T2 | Checksum failure: on a scratch copy of the tree, flip one byte in one `.tgz` and one `.whl`, then run verify-deps and install | Both fail, name the file and show expected and actual hash; install stops before creating the install root; no network events |
| T3 | Missing artifact: on a scratch copy, move one wheel and the Electron zip out, then run install | Fails, names the path and `manifests/checksums.sha256`; no network events |
| T4 | Clean install: `install-offline.ps1` with default paths | Exit 0; `app\Hermes.exe`, venv, runtimes and launchers present; home seeded; zero public network events |
| T5 | `verify-offline.ps1` | Pass, including `updates.check: false` and no update status in `--version` |
| T6 | CLI smoke, mock provider (see §4): `hermes-offline.cmd -z "Say hello"` | Mock reply returned; exit 0; mock server logged one `/v1/chat/completions`; zero public network events |
| T7 | Desktop smoke via `launch-hermes.cmd`: boot, first-run screen, chat with the mock, close, relaunch, chat again | Both chats succeed; the backend process is `<install>\venv\Scripts\python.exe` (check the process tree); the update panel reports "not-a-git-checkout" rather than a fetch error; zero public network events |
| T8 | Desktop launched **directly** (`app\Hermes.exe` from Explorer, no launcher environment) | Expected risk (§5): falls through to upstream's networked bootstrap. Pass = a clear offline error and no install attempt. Record the actual behavior |
| T9 | Backend unavailable: rename `venv\Scripts\hermes.exe`, then launch via the launcher | Same bootstrap-fallback risk as T8. Pass = a visible failure, no `install.ps1`/`git clone`/`pip` attempt |
| T10 | Lifecycle: `install-offline.ps1 -Force` over T4; induce a failure mid-install (make `vendor\python` unreadable) and confirm rollback; remove the install root | The home and its `config.yaml` survive `-Force`; a failed `-Force` restores the previous install; removing the install root plus home leaves no files elsewhere (compare `%LOCALAPPDATA%`/`%APPDATA%`/`%TEMP%` against S1; Electron user-data is expected, so list it) |
| T11 | Secret hygiene: scan the full tree (including `upstream/`, reviewed separately) for key and token patterns and for `.env`, `auth.json`, `*.pem` files | Only examples and upstream test fixtures, each listed and justified |
| T12 | Lazy-install refusal: run a CLI feature whose optional dependency is not vendored (e.g. a voice or browser toolset) | Fails as "unavailable" with no pip, uv, npm or npx process spawned (Process Monitor filter on process name) and no network events |

T8, T9 and T12 are expected to find gaps. A gap is recorded with an owner and a fix in `reports/final-gap-list.md` and does not block the rest of the run. A public network attempt during **T1–T7** does block Phase 4 until it is fixed.

## 4. Mock inference provider

Use upstream's `tests-js/scripts/mock-server.ts`. It depends only on Node built-ins and runs under the bundled Node 26 with native type stripping, so it needs no npm install.

- Add `tests/phase4/Start-MockProvider.ps1`. It runs `runtime\node\node.exe` on a small wrapper that imports the mock server's library entry, listens on `127.0.0.1:<fixed port>` (upstream listens on port 0, so the wrapper passes a fixed port or prints the chosen one), and logs requests to the evidence folder.
- Use a test-only Hermes home created by the harness, not the user home. It gets the mock's config shape from upstream's `writeMockConfig`: `model.provider: mock`, `providers.mock.api: http://127.0.0.1:<port>/v1`, `key_env: MOCK_API_KEY`. `.env` holds a placeholder key. Point the launchers at it with `OFFLINE_HERMES_HOME`.
- The mock does not simulate tool calls. T6/T7 prove boot → backend → inference → UI, not tool execution.

Check during setup: `config/hermes.example.yaml` uses `providers.<name>.base_url`, while the mock uses `providers.<name>.api`. Confirm which one upstream accepts, and fix the example if needed.

## 5. Known risks going in

1. **Desktop bootstrap fallback (high).** In `apps/desktop/electron/main.ts`, `resolveHermesBackend` tries four sources in order: `HERMES_DESKTOP_HERMES_ROOT`, the dev source, `ACTIVE_HERMES_ROOT` (`<HERMES_HOME>\hermes-agent`), then `HERMES_DESKTOP_HERMES`. If all fail, including a failed `--version` probe, it falls through to upstream's first-run bootstrap, which runs the networked installer. Our launcher sets `HERMES_HOME` and `HERMES_DESKTOP_HERMES`, so the launcher path should be safe. Opening `Hermes.exe` directly, or a broken backend, probably is not (T8, T9).
   Candidate fix: stop exposing a bare `Hermes.exe` shortcut; the Phase 5 installer creates shortcuts only to the launcher. Alternatively, a small wrapper patch in `patches/` if a clean upstream hook for disabling bootstrap does not exist. Decide after T8.
2. **Desktop self-update check.** `checkUpdates` calls `api.github.com` only when the resolved update root has a `.git` directory. Our installed source has none, so it should report `not-a-git-checkout`. T7 confirms this with the firewall log.
3. **Clients that ignore proxy variables.** The install-time guard does not cover them; the firewall harness does. Any drop recorded during T4 names the offending process.
4. **Install time and resources.** Phase 3 took 14 minutes on a fast host. Record VM timings; a significantly slower run is a usability finding, not a failure.
5. **`hermes --version` probe timeout inside the desktop app.** A slow first Python start on a cold VM could trip the probe and trigger the fallback in risk 1. Measure the cold-start `--version` time in T5.

## 6. Work to build before the run

In priority order:

1. `tests/phase4/Enable-NetworkBlock.ps1`, `Assert-NetworkBlocked.ps1`, `Collect-NetworkEvidence.ps1`
2. `tests/phase4/Start-MockProvider.ps1` and wrapper, plus the test-home setup
3. `tests/phase4/Invoke-Phase4.ps1`: runs P0–T7 and T10–T11 unattended, writes the evidence folder and draft reports
4. The manual T7/T8/T9 desktop steps as a checklist in `tests/phase4/desktop-checklist.md`; they need UI interaction and a process-tree check. Screenshots go in the evidence folder.
5. Report templates for the four required reports.

Scripts 1–3 are developed on the connected host against a disposable local VM, and must themselves pass `tests/phase3/static-checks.sh`-style checks (no public URLs outside the assertion targets).

## 7. Sequence

1. Build the harness (§6.1–6.3) and dry-run it on a VM snapshot with the network *allowed*, so that the evidence collection shows real traffic and the assertions demonstrably fail.
2. Take `S0-clean`, stage the repository, block the network, and take `S1-staged`.
3. Full run: P0, T1–T12. Collect evidence and draft the reports.
4. Fix blocking findings (any public network event in T1–T7), rebuild, and rerun from `S1-staged`. Repeat until clean.
5. Write `reports/final-gap-list.md` with the T8/T9/T12 outcomes and the Phase 3 open items (non-relocatable `build-bundle.ps1` output, `Invoke-CheckedCommand` quoting) as the Phase 5 input.

## Out of scope for Phase 4

Linux, macOS and ARM64; general browser automation; voice; messaging bridges; bundled model weights; Honcho and MCP servers (local-endpoint health checks only if configured); signed release installers (Phase 5); upstream refresh simulation (Phase 6).
