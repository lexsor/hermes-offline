# Phase 6: upstream update simulation

Two controlled refreshes of this distribution against real upstream commits, run on 2026-09-25 with the Phase 6 tooling (`docs/upstream-update-workflow.md`). Both ran in a separate Git worktree on local branches that are never merged, so `main` stays on upstream `bc655bf`.

| | Simulation A | Simulation B |
|---|---|---|
| Target | Upstream `main`, `d0cb567273` (2026-09-25) | Upstream release v0.21.5, `f97608f178` (2026-09-24) |
| Distance from the pin | 3,998 commits, 7,341 files | 1,770 commits, 4,903 files |
| Import | Byte-identical tree `90ec9f15` | Byte-identical tree `5849eacd` |
| Outcome | **Refresh correctly blocked**; the update needs porting work (G20) | **Full cycle passed**: import, review, one new patch, refresh, offline install, `verify-offline`, uninstall |
| Reports | [`upstream-updates/bc655bfb40..d0cb567273.md`](upstream-updates/bc655bfb40..d0cb567273.md) | [`upstream-updates/bc655bfb40..f97608f178.md`](upstream-updates/bc655bfb40..f97608f178.md), [`upstream-updates/refresh-f97608f178.md`](upstream-updates/refresh-f97608f178.md) |

## Before the simulations: the selection rules

Phase 2 did not record how the 68 wheels and 1,027 npm tarballs were chosen. `profiles/windows-x64-desktop.toml` now states the rules. Applied to the pinned upstream, `ohmaint.py check` reproduces `python.lock` and `node.lock` exactly: the same artifacts, the same lock paths, and the same records.

A forced rewrite of every manifest (`refresh --force-rewrite`) left `git diff` empty. A removal test (two leaf packages excluded) and a re-add test (both downloaded again from PyPI and npm) produced exactly the expected manifest changes. The re-added records matched the originals except for the review status, which is marked for human review, as it should be.

One real Phase 2 omission surfaced: `socksio`, which is required through `httpx[socks]`, was never vendored. It is now an explicit, documented exclusion (G19).

## Simulation A: upstream `main`

`update-upstream.sh --ref main` imported `d0cb567273` and wrote the surface report. `refresh-vendor-artifacts.sh` then stopped with exit code 2 and wrote nothing, for these reasons:

| Blocking item | What it means |
|---|---|
| **Profile Python outdated** | Upstream's `uv.lock` is resolved only for Python ≥ 3.14, and all 44 direct dependencies are now gated on `python_version >= '3.14'`. A mechanical refresh would have produced a 3.11 closure without `pyyaml`, `rich`, `openai` and the rest of the core dependencies. |
| **electron-builder 27.0.0-alpha.6** | The NSIS, NSIS-resources, WiX and 7zip toolsets were reviewed against 26.15.3 and need a new review. |
| **Patch 0002 does not apply** | Upstream changed `apps/desktop/electron/main.ts` at the patched lines. Patch 0001 still applies; its target changed but not at the patched lines. |
| **`lucide-react` undeclared** (found in Simulation B; also on `main`) | See below. |

The report also records new network surface that the next real update must handle: an upstream `pm/` package manager that downloads runtimes and tools from `hermes-assets.nousresearch.com` and GitHub releases; a desktop updater (`apps/desktop/electron/updater/`, `app-updater.ts`, App Installer and Store checks through `winrt-windows-services-store`); `electron-updater`; and 110 runtime files with new URLs or client calls. This is recorded as gap G20.

**Outcome:** this is the result the workflow is for. The tooling found every change that makes this upstream a porting job rather than a refresh, and it refused to produce vendor changes for it.

## Simulation B: upstream v0.21.5

The newest lockfile-changing upstream commits before the 2026-09-24 "bundles & unified installer" change were all free of blocking items with both patches applying. The simulation used the release commit v0.21.5.

1. **Import:** `update-upstream.sh --ref f97608f178` gave a byte-identical tree. `manifests/upstream.lock` was updated, and 81 executable-bit modes were set from upstream's tree.
2. **Review** of the [surface report](upstream-updates/bc655bfb40..f97608f178.md):
   - Python closure unchanged: 68 wheels.
   - npm: one new package, `@novnc/novnc` 1.7.0 (MPL-2.0; a VNC client for the desktop's bot screen pane).
   - Pinned runtimes all consistent. Patches 0001 and 0002 apply; upstream changed `main.ts` elsewhere.
   - **Blocking:** `lucide-react` is imported by `apps/desktop/src/components/onboarding-chat/cards/setup.tsx` (upstream `6ec517c475`), but only the `web` and `bootstrap-installer` workspaces declare it. A full upstream `npm ci` hoists it; the offline installer's `npm ci --workspace apps/desktop` does not.
   - Network surface: 32 runtime files with added URLs or client calls. The ones that reach the network when used are the Codex model catalog (`agent/model_metadata.py`, `hermes_cli/codex_models.py`: the Codex provider only), plugin-catalog presence checks and the skills hub (existing gap G12), an OpenRouter video-model listing (plugin), and the novnc WebSocket (connects only to a user-configured bot desktop). The rest are documentation strings, placeholders, loopback addresses or CI. None of them is on the default path of a configured local provider.
3. **How the `lucide-react` finding was made.** It was first found the hard way: the first offline install of the refreshed tree failed in the desktop build (`Rolldown failed to resolve import "lucide-react"`, exit 1, no partial install left behind, no network fallback). The import scan was added to the tooling as a result. The same surface report now marks it as blocking before anything is downloaded or built.
4. **Fix**, as the workflow prescribes: patch `0003-desktop-declare-lucide-react.patch` declares `lucide-react` 0.577.0 (the version the lock already pins) in `apps/desktop/package.json` and in the lock's `apps/desktop` entry. It is registered in `manifests/patches.lock`, and `lucide-react` is added to `[[node.extra_packages]]` in the profile.
5. **Refresh:** two downloads, each verified against its `package-lock.json` SRI before anything was written: `@novnc/novnc` and `lucide-react`. The manifest diff is exactly those two artifacts: `node.lock` 1,027 → 1,029, two `licenses.lock` records marked for human review (novnc's six embedded license files, including MPL-2.0 and OFL-1.1, were found), two checksum lines, and the vendor README count.
6. **Checks:** `ohmaint.py check` (68 wheels, 1,029 tarballs); `tests/phase3`, `phase4` and `phase6` static checks; `verify-deps.sh` and `verify-deps.ps1` (1,112 files).
7. **Offline install** from the refreshed tree into a new location: pass in 15 minutes, with all three patches applied. `verify-offline`: **Hermes Agent v0.21.5**, Python 3.11.16, pass. `uninstall-offline.ps1 -RemoveHermesHome -RemoveBackups` then removed the install and the home.

The simulation branch `upstream-update/f97608f178` (commit `e888336`) was never pushed. It was deleted with the worktree after the run; this report, the linked surface and refresh reports, and the appendix preserve what it contained.

## Findings folded back into the tooling

| Found during | Problem | Fix in `scripts/maintenance/ohmaint.py` |
|---|---|---|
| First import | Git on Windows added upstream's executables as mode 644, and skipped 27 files that upstream tracks but its own `.gitignore` matches. The byte-identity check stopped the import. | Add with `-f`, then set each entry's mode from upstream's tree listing. Any content difference still fails, listing the paths. |
| Simulation A | A `uv.lock` resolved only for Python ≥ 3.14 drops the per-dependency markers, so a 3.11 closure looked valid. | Blocking check on `resolution-markers` and on pyproject's own markers. |
| Simulation A | Patch 0001 (a plain unified diff) was reported as not applying. | Patch targets are read from the `---`/`+++` lines. |
| Simulation B | A short commit ID cannot be fetched. | Resolve commit IDs already in the clone first. |
| Simulation B | Undeclared, hoisted imports only surfaced in the 15-minute desktop build. | Import scan (blocking), with `[[node.extra_packages]]` in the profile. |
| Both | The network section was dominated by translation strings, `*.example.com` placeholders, CI workflows and plugin-catalog data. | Those are counted, not listed; CI workflows appear under installer changes. |

## What was not done

- The offline installs in these simulations ran with outbound networking **not** blocked. Phase 4's network-blocked record run was not repeated for v0.21.5. The workflow requires that before an update is merged, and the next real update must do it.
- There was no live desktop chat smoke test on v0.21.5 (the Phase 4 T6/T7 equivalent).
- Neither simulation branch is merged. The distribution stays on `bc655bf`. Patch 0003 lives only on the simulation branch; its text is below for the next real update.

## Appendix: patch 0003

```diff
--- a/apps/desktop/package.json
+++ b/apps/desktop/package.json
@@ -127,6 +127,7 @@
     "https-proxy-agent": "7.0.6",
     "ignore": "7.0.6",
     "katex": "0.16.47",
+    "lucide-react": "0.577.0",
     "mermaid": "11.16.1",
     "motion": "12.42.2",
     "nanostores": "1.4.2",
--- a/package-lock.json
+++ b/package-lock.json
@@ -117,6 +117,7 @@
         "https-proxy-agent": "7.0.6",
         "ignore": "7.0.6",
         "katex": "0.16.47",
+        "lucide-react": "0.577.0",
         "mermaid": "11.16.1",
         "motion": "12.42.2",
         "nanostores": "1.4.2",
```
