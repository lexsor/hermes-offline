# Phase 5: distribution

## Decisions

| Question | Decision | Why |
|---|---|---|
| Release form (gap G7) | **Repository archive plus on-target install.** `scripts/build-bundle.ps1` archives the committed tree; the target runs `install-offline.ps1` from it. | A Python venv and its console-script launchers embed absolute paths, so an installed tree is not relocatable. The repository-plus-installer path is the one Phase 4 validated, network-blocked. A prebuilt relocatable install would need new relocation code and a new validation run. |
| Containers | **Deferred.** No Dockerfile, Compose file or image. | The only profile is the Windows x64 desktop. A Linux image needs its own vendored closure, license review and network-blocked validation (a future `container-linux-x86_64` profile). A Windows container cannot run the desktop. Recorded in `RELEASE_NOTES.md`. |
| Uninstall (gap G6) | **`scripts/uninstall-offline.ps1`** added. | Phase 4 left uninstall to Phase 5. |
| Third-party notices | **Generated at build time** into the archive as `THIRD-PARTY-NOTICES.md`, from `manifests/licenses.lock`. | `reports/redistribution-exceptions.md` requires Phase 5 to aggregate notices. Generating the file from the lock keeps it from drifting. It indexes where each license text lives inside its artifact, plus the GPL/MPL source offers; it does not replace the legal review (G11). |

## Deliverables

| File | Purpose |
|---|---|
| `scripts/build-bundle.ps1` (rewritten) | Maintenance command, no network access. Refuses a dirty tree unless `-AllowDirtyTree` is passed, which is recorded in the manifest. Stages exactly `git ls-files` from the working tree, so LFS content ships rather than pointers. Verifies all vendored checksums on the staged copy, then generates `RELEASE-MANIFEST.json`, `THIRD-PARTY-NOTICES.md` and `release-files.sha256`, and verifies the staged tree against that list. It then archives with `tar.exe` (zip64 and long paths), reads the archive back to check the entry count, and writes the `.zip.sha256` and a copy of the manifest. |
| `scripts/verify-release.ps1`, `.sh` | Checks an extracted release: every listed file present with its hash, and no unlisted file. It uses `\\?\` paths, so it works on upstream files beyond 260 characters under Windows PowerShell 5.1. The `.sh` form runs `sha256sum -c` on a POSIX transfer host. |
| `scripts/install-offline.ps1` (small change) | When `RELEASE-MANIFEST.json` is present, it also runs the release-tree check before changing anything, and records `release_version` in `install-state.json`. |
| `scripts/uninstall-offline.ps1`, `.sh` | Removes the install root and the verify cache. With switches it also removes the Hermes home (`-RemoveHermesHome`) and the `-Force` backups and leftover staging folders (`-RemoveBackups`). Supports `-WhatIf`. |
| `scripts/lib/OfflineHermes.psm1` | Adds `Get-LongPath`, `Get-FileSha256`, `Get-ReleaseTreeFiles` and `Test-ReleaseTree`. |
| `RELEASE_NOTES.md` | Release status and gates, supported platforms, manual prerequisites, transfer, verify, install and uninstall steps, known limitations, the container deferral, and maintainer build steps. |
| `tests/phase3/static-checks.sh` | New invariants: the bundle is built from `ls-files` and never from an installed tree; the installer checks release trees; the uninstaller keys on `install-state.json`, supports `-WhatIf` and never removes the online Hermes folders. |

## Test run (development laptop, 2026-09-25)

Windows 11 Pro 26200, Windows PowerShell 5.1 for all scripts. The build used `-AllowDirtyTree` because these changes were not yet committed, so that archive contained the modified tracked scripts but not the four new, untracked ones; those ran from the repository against the extracted tree. The network was **not** blocked for this run; it tests packaging and relocation, not the offline guarantee (see "Still to do").

| Step | Result |
|---|---|
| `build-bundle.ps1` | Pass, in 4 min 23 s: 15,881 release files, 1,110 vendored artifacts, 2 patches, a 588 MB zip. The dirty-tree warning was printed and the changes were listed in the manifest. A second build, after the notices generator was added, produced 15,882 files including `THIRD-PARTY-NOTICES.md` (1,110 artifacts indexed); its extraction passed `verify-release`. The install and uninstall rows below used the first build. |
| `tar.exe -xf` into a scratch folder, whose deepest path is 333 characters | Pass |
| `verify-release.ps1` on the extracted tree | Pass: 15,881 files |
| Negative checks: a missing upstream file at the 333-character path, a patch with one added byte, an extra script | Each failed with exit code 1, naming the file and the category (missing, checksum mismatch, not in the release). After restoring the tree, it passes again. |
| `verify-release.sh` (Git Bash, `sha256sum`) | The hashes pass. It refused a folder that is not a release, and it caught one extra file (coverage mismatch). |
| `verify-deps.ps1` on the extracted tree | Pass: 1,110 files |
| `install-offline.ps1` from the extracted tree into a new location (not the build path) | Pass, in 12 min. The installer ran the release-tree check (15,881 files) before changing anything; `install-state.json` records `release_version` `0.21.3-offline.fb2e1e3`; the desktop app contains `LICENSE.electron.txt` and `LICENSES.chromium.html`. |
| `verify-offline.ps1` | Pass: Hermes Agent v0.21.3, Python 3.11.16 |
| Sizes | Archive 0.59 GB, extracted 0.67 GB, install 1.73 GB |
| Uninstall refusals: a folder without `install-state.json`, `%LOCALAPPDATA%` itself, a running `node.exe` from the install | Each refused with exit code 1 and removed nothing. |
| `uninstall-offline.ps1 -RemoveHermesHome -RemoveBackups -WhatIf` | Listed the install and the home; removed nothing. |
| Uninstall, default | Removed the install and kept the home. It reported this laptop's online `%LOCALAPPDATA%\hermes` and `%APPDATA%\Hermes` without touching them. |
| Uninstall with an explicit `-HermesHome` after the install was gone | Removed the home. |
| Uninstall `-RemoveBackups` on a mock install with a `.previous-*` backup and a `.staging-*` folder | Removed all three. |
| `tests/phase3/static-checks.sh`, `tests/phase4/static-checks.sh`, Windows PowerShell 5.1 parse of every changed script | Pass |

## Still to do before the release is public

1. **Build the release from a committed tree** and record its `.sha256`, now without `-AllowDirtyTree`.
2. **Network-blocked recheck from the release archive** on the Azure VM. Stage the zip in place of the working-tree export, run `verify-release`, then install, then T6/T7, then `uninstall-offline` (T10c, gap G6), with the same evidence collection.
3. **The release gates** in `RELEASE_NOTES.md`: legal review (G11), the full upstream secret-hit review (G16), a standard-user run (G8), and Windows 10 or a narrowed claim (G14).
4. **Phase 6**, the upstream update workflow.
