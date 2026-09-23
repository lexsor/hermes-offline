# Phase 3 native Windows run

Date: 2026-09-23
Host: Windows 11 Pro 10.0.26200 x64, PowerShell 7.6.6, long paths enabled.
Upstream: `bc655bfb40ff7414bbec9dd179b17cf41e2f60ba` (see `manifests/upstream.lock`).

This was the first execution of the Phase 3 scripts on native Windows. The scripts had previously been written but not run. Outbound networking was **not** blocked on this host, so this is not a Phase 4 result.

## Results

| Step | Result |
|---|---|
| `scripts/verify-deps.ps1` | Pass: 1110/1110 vendored files match `manifests/checksums.sha256` (1.7 s) |
| `tests/phase3/static-checks.sh` | Pass |
| `scripts/install-offline.ps1`, first run (original script) | Exit 0, but **not offline-correct** (defects 1–3 below) |
| `scripts/install-offline.ps1`, after fixes | Pass, 14.2 min, unpacked `app\Hermes.exe` built from the vendored Electron runtime |
| `scripts/verify-offline.ps1`, after fixes | Pass, with no update check performed |
| Missing-artifact failure path (`verify-deps.ps1 -RepoRoot` against a manifest naming an absent wheel) | Pass: exit 1, names the missing path and the manifest |

## Defects found and fixed

1. **Electron network fallback (critical).** The installer extracted the vendored Electron runtime into `<source>\node_modules\electron\dist`. npm actually installs `electron` nested under `apps\desktop\node_modules\electron`. Upstream's `run-electron-builder.mjs` found no local dist and silently fell back to `@electron/get` (`downloaded label=electron`). On this host the request was served from a user-global cache (`%LOCALAPPDATA%\electron\Cache`, written 2026-07-30 by a separate online Hermes install). On a clean host it would have downloaded from GitHub.
   Fix: `Resolve-NodePackageDirectory` locates `electron`, `get-windows` and `esbuild` the way Node resolves them from `apps/desktop`. The builder refuses to start without `dist\electron.exe`. The rerun logs `using custom unpacked Electron distribution`.
2. **No guard against implicit downloads.** Nothing stopped a proxy-aware client from reaching the network, and host-level caches could hide a missing artifact.
   Fix: `Get-OfflineNetworkGuard` is applied to every child process for the whole install and for `verify-offline.ps1`. It points `HTTP(S)_PROXY`, `ALL_PROXY`, npm proxy settings, global-agent and `ELECTRON_MIRROR` at a closed loopback port. It also redirects `electron_config_cache` and `ELECTRON_BUILDER_CACHE` to empty per-install directories and sets `ELECTRON_SKIP_BINARY_DOWNLOAD`, `PIP_NO_INDEX`, `UV_OFFLINE` and `HERMES_DISABLE_LAZY_INSTALLS`. The caller's environment is restored afterwards.
3. **Shared Hermes home and live update check.** With no `HERMES_HOME` set, the offline install used the host's online Hermes home (`%LOCALAPPDATA%\hermes`), so its state, credentials and update cache were shared. `hermes --version` reported `Update available: 16776 commits behind`, and the passive check calls `api.github.com`.
   Fix: new `-HermesHome` parameter (default `%LOCALAPPDATA%\OfflineHermes-home`, which must be outside the install root). The launchers always pin it, with `OFFLINE_HERMES_HOME` as an override. On first install it is seeded with `updates.check: false` and telemetry off, and an existing `config.yaml` is never overwritten. `verify-offline.ps1` asserts `updates.check` is false and that `--version` printed no update status.
4. **Stale absolute paths after the staging move.** The venv and all 68 wheels were installed in the staging directory, which was then renamed. Only `pyvenv.cfg` and `hermes.exe` were repaired. Every other pip console-script launcher and the `activate` scripts still pointed at the deleted staging path.
   Fix: the venv and all pip installs now run after the atomic move. A failure after the move removes the partial install and restores any `-Force` backup. `verify-offline.ps1` checks that the launchers contain no staging path.
5. **Smaller fixes.**
   - `config/hermes.example.yaml` used keys Hermes does not recognize (`offline:`, `api_key_env`). It now uses upstream's schema (`model.provider: custom`, `providers.<name>.key_env`, `updates.check`).
   - Launcher `HERMES_HOME` lines are split into plain lines, so paths containing `(x86)` work, and the `.cmd` files are written with CRLF.
   - `build-bundle.ps1` uses a temporary Hermes home, so building a bundle never touches the user's home.
   - `static-checks.sh` gained regression guards for defects 1–3. It now fails if `rg` is missing, because its negative `if rg …` checks would otherwise pass vacuously. The regex also avoids `\\`, which Git Bash collapses; the guard was confirmed to match the original faulty line.

## Open items for Phase 4/5

- **Blocked-network validation is still required.** The guard only stops clients that honor proxy variables. Phase 4 must run on a clean Windows x64 VM with outbound traffic blocked by firewall, and with no `%LOCALAPPDATA%\electron`, npm or pip caches. This host's pre-populated Electron cache is exactly what hid defect 1.
- **Desktop smoke test not yet run.** Not yet exercised: launching `Hermes.exe`, the Electron-to-backend spawn via `HERMES_DESKTOP_HERMES`, first-run setup, a chat against a local/mock provider, and whether the desktop shell performs its own update or telemetry calls.
- **`build-bundle.ps1` produces a non-relocatable archive.** It zips an installed tree whose venv and launchers embed the temporary install path. Phase 5 needs either a relocatable venv strategy or to ship the repository plus installer, not the installed tree.
- **`Invoke-CheckedCommand` quoting.** It does not escape a trailing backslash inside a quoted argument. No current call site hits this, but it will matter if install paths with spaces end in `\`.
