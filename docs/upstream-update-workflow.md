# Upstream update workflow

How to move this distribution to a newer upstream Hermes Agent commit. Run it on a connected maintenance machine. The target machines never run any of it.

## Online and offline commands

| Command | Network | Purpose |
|---|---|---|
| `scripts/update-upstream.sh` | Online: the upstream Git repository | Import a new upstream commit into `upstream/hermes-agent` |
| `scripts/diff-dependency-surface.sh` | Online if the clone lacks the file contents (blobless clone) | Report what changed between two upstream commits |
| `scripts/refresh-vendor-artifacts.sh` | Online: PyPI, npm registry. `--dry-run` is local only | Re-vendor the Python wheels and npm tarballs |
| `scripts/maintenance/ohmaint.py check` | Local only | Prove the profile's rules reproduce the committed manifests (also run by `tests/phase6/static-checks.sh`) |
| `install-offline`, `verify-*`, `build-bundle`, `uninstall-offline` | None | The offline path. None of these call the maintenance tool (checked by `tests/phase6/static-checks.sh`) |

Maintenance host requirements: Git, Bash (Git Bash on Windows works), Python 3.11 or newer with `packaging` (pip's bundled copy is used if it is not installed), and Git LFS. Windows PowerShell is needed for the offline validation steps.

## Where the rules live

`profiles/windows-x64-desktop.toml` states how the vendored closures are chosen from upstream's lockfiles. Phase 2 did not record this; Phase 6 reconstructed the rules and checked them against the committed manifests.

- **Python:** the default dependencies of the project in `uv.lock` (no extras), plus the `[build-system]` requirements. Markers are evaluated for CPython 3.11.16 on Windows AMD64, and the best-ranked `cp311`/`win_amd64` wheel is chosen. `wheel` is pinned in the profile because upstream leaves it unpinned. `socksio` is excluded, recording the Phase 2 omission (gap G19).
- **npm:** the dependencies, devDependencies, optional dependencies and non-optional peer dependencies reachable from the `apps/desktop` and `apps/shared` workspaces in `package-lock.json`, resolved with Node's `node_modules` lookup and filtered to `win32`/`x64`. Rolldown's WASI fallback is excluded.
- **Install scripts:** every closure package with an npm lifecycle script is listed with how the offline installer handles it. The installer runs npm with `--ignore-scripts`, so a new one must be reviewed.
- **Imports:** every bare module import in `apps/desktop/src`, `apps/desktop/electron` and `apps/shared/src` must name a closure package. Path aliases (`@/`) and workspace packages (`@hermes/`) are skipped. Upstream's monorepo can resolve an undeclared import through another workspace's hoisted install, which the offline `npm ci --workspace apps/desktop` does not do. Such a package goes in `[[node.extra_packages]]`, and a patch declares it for `apps/desktop` (see patch 0003 in the simulation report).
- **Profile Python:** a refresh is blocked when `uv.lock` is resolved only for other Python versions, or most direct dependencies are gated to them. The vendored CPython must follow upstream first.
- **Pinned runtimes:** the vendored binaries whose version must follow an npm package: Electron, the get-windows native binding, the Lightning CSS sources, and the electron-builder toolsets, which are reviewed against `app-builder-lib`.

Python, Node, PortableGit, ripgrep and uv are distribution choices, not derived from upstream. They are updated by hand in `manifests/binaries.lock` when needed.

## Procedure

Start from a clean, committed `main`.

### 1. Import

```bash
scripts/update-upstream.sh --ref main          # or a tag or commit
```

This creates the branch `upstream-update/<commit>` and replaces `upstream/hermes-agent` with the new commit's tree. It stops unless the imported tree hash equals upstream's (a byte-identical import), then updates `manifests/upstream.lock` and writes `reports/upstream-updates/<old>..<new>.md`. Everything is staged; nothing is committed. The upstream clone is `.maintenance/upstream.git`, a blobless bare clone created on first use; `--git <dir>` or `OFFLINE_HERMES_UPSTREAM_GIT` chooses another.

### 2. Review the surface report

The report has one section per question in `AGENTS.md`:

| Section | What to decide |
|---|---|
| Dependency sources | Closure changes, new non-registry sources, other lockfiles and manifests, `requires-python` and `engines` changes |
| Vendor refresh plan | Wheels and tarballs to add or remove. **Blocking** items: a changed hash for an unchanged version, a pinned runtime needing a manual update, an unreviewed install script, an undeclared import, an outdated profile Python |
| New network access paths | Each added URL, download tool, package install, HTTP client or model download in runtime code: harmless, blocked by the profile, or a new gap. Add confirmed ones to `reports/network-access-inventory.md` |
| Installer and bootstrap behavior | Changed install/update/packaging files and npm scripts, compared against `install-offline.ps1` |
| Offline patches | Whether each patch still applies, and whether upstream changed its targets |
| Licenses | License files and the project license; npm license fields for packages whose version did not change |

A patch that no longer applies is rewritten against the new source, and its hash updated in `manifests/patches.lock`. A pinned runtime is updated by hand: vendor the new artifact, record it in its lock with source URL, SHA-256 and license, and add it to `checksums.sha256`. For a reviewed toolset, also update `npm_version` in the profile.

### 3. Refresh the vendored artifacts

```bash
scripts/refresh-vendor-artifacts.sh --dry-run
scripts/refresh-vendor-artifacts.sh --report reports/upstream-updates/refresh-<commit>.md
```

It downloads every new wheel and tarball into memory and checks each against the hash in `uv.lock` or `package-lock.json`. Only after all of them pass does it write any file. It then removes artifacts that left the closure and rewrites `python.lock`, `node.lock`, `licenses.lock` (including the summary counts), `checksums.sha256` and the counts in `vendor/README.md`. Records of unchanged artifacts are kept byte for byte. New license records are marked `automated_refresh_metadata_and_archive_inspection` for human review. If an unchanged vendored file no longer matches its old checksum, the refresh stops.

### 4. Verify and validate

```bash
python scripts/maintenance/ohmaint.py check
bash tests/phase3/static-checks.sh && bash tests/phase4/static-checks.sh && bash tests/phase6/static-checks.sh
```

Then, on Windows:

```powershell
.\scripts\verify-deps.ps1
.\scripts\install-offline.ps1 -InstallRoot <scratch> -HermesHome <scratch-home>
.\scripts\verify-offline.ps1 -InstallRoot <scratch>
```

Before the update is merged, repeat the Phase 4 network-blocked record run (`docs/phase-4-record-run.md`), because new code can bring new network access that only a blocked run shows. Update `reports/final-gap-list.md` with anything new.

### 5. Commit, review, merge

Commit on the `upstream-update/<commit>` branch: the import, the report, the refreshed manifests and artifacts, and any patch changes. Review the diff of `manifests/` in particular. Changed checksums must be exactly the added and removed artifacts. Then merge and build a release (`scripts/build-bundle.ps1`).

## What the workflow detects

| `AGENTS.md` requirement | Where |
|---|---|
| New dependency sources | Surface report: closures, non-registry sources, other manifests and lockfiles, `.gitmodules` |
| New network calls | Surface report: new network access paths |
| Changed licenses | Surface report: licenses; refresh: license metadata of each new artifact |
| Changed checksums | Refresh: a hash change for an unchanged version blocks; `checksums.sha256` diff at review; `check` fails on drift |
| Changed installer behavior | Surface report: installer and bootstrap files, npm scripts, patch applicability, new install scripts, undeclared imports that break the workspace-scoped install |

## Limits

- The network scan is a pattern match over added lines. It finds URLs and common client calls, but not a new network path built from existing helpers. The Phase 4 blocked run remains the proof.
- In the surface report, the import scan covers only added lines (reading every file of a blobless clone would fetch it). `check` and `refresh` scan the whole imported tree.
- The offline install is still the final test of the npm closure: a build step can need a package no declaration or import shows.
- Python license metadata of unchanged wheels is not re-read; a wheel's license cannot change without its version changing.
- The simulation of this workflow is recorded in `reports/phase-6-update-simulation.md`.
