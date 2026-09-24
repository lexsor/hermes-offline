# Phase 4: checksum verification

**Result: pass.** Every vendored artifact was verified against `manifests/checksums.sha256` on the offline VM. Altered and missing artifacts were refused by both the verifier and the installer, with the exact path, and nothing was installed or downloaded.

Record run: `phase4-20260924-180727`, Windows 11 Pro 10.0.26200 (Azure VM), Windows PowerShell 5.1, outbound networking blocked.

## What is verified

| Manifest | Scope | Verified by |
|---|---|---|
| `manifests/checksums.sha256` | 1110 files under `vendor/`: 68 Python wheels, 1027 npm tarballs, 10 runtime/tool binaries, the Electron runtime, 3 source archives, `vendor/README.md` | `scripts/verify-deps.ps1`, and `install-offline.ps1` before any change. Unlisted files under `vendor/` are rejected too |
| `manifests/patches.lock` | `patches/0001-desktop-no-remote-theme-fonts.patch`, SHA-256 `340e40f3…4347` | `install-offline.ps1` (`Install-UpstreamPatches`) before `git apply --check`, and `tests/phase3/static-checks.sh` |
| `manifests/upstream.lock` | Upstream tree `8196c19` | At commit time: the staged `upstream/hermes-agent` subtree hashes to exactly this tree |

## Results

| Case | Mutation | `verify-deps.ps1` | `install-offline.ps1` | Install root created | Public network attempts |
|---|---|---|---|---|---|
| T1 | None | Pass, 1110/1110 | n/a | n/a | 0 |
| T2a | One byte flipped in the last npm tarball | Exit 1: `Checksum mismatch` naming the file, with expected and actual hashes | Exit 1, same message | No | 0 |
| T2b | One byte flipped in the first wheel | Exit 1, same | Exit 1, same | No | 0 |
| T3a | First wheel removed | Exit 1: `Missing required artifact` naming the file and `manifests/checksums.sha256` | Exit 1, same | No | 0 |
| T3b | Electron runtime zip removed | Exit 1, same | Exit 1, same | No | 0 |
| T10b | Corrupted wheel, `-Force` over an existing install | n/a | Exit 1: `ERROR: Checksum mismatch: vendor\python\windows-x64-cp311\annotated_doc-0.0.4-py3-none-any.whl` | Existing install untouched: no new backup, and `verify-offline` still passes | 0 |

T2 and T3 run on scratch copies of `vendor/`, `manifests/` and `scripts/` (`Invoke-Phase4.ps1`). The repository itself is never mutated.

Failure output is a plain `ERROR: <message>` line on stderr. Windows PowerShell 5.1's `Write-Error` formatting used to wrap artifact names mid-phrase (found in Phase 3, fixed in `7094529`).

## Transport integrity (before going offline)

- The vendored archives are stored with **Git LFS**. A clone without `git lfs pull` contains pointer stubs, which fail `verify-deps` as checksum mismatches, so an incomplete transfer cannot go unnoticed.
- On the VM: clone, then `git lfs pull` (≈530 MB), then `verify-deps` passed 1110/1110 while still online.
- `New-Phase4Vm.ps1 -Stage Export` verified the checksums again on the export, before creating the tar that was tested.
- **Portable Git**, used only to clone and then deleted, was the pinned build from `manifests/binaries.lock`. Its SHA-256 (`bea006a6…f311`) was checked before use.

## Not covered

- **Signatures.** Checksums prove the artifacts match the manifests, not who produced them. The manifests record source URLs, but there's no signature verification of upstream releases. This is a Phase 5/6 item; see gap G11.
- **Patches after an upstream refresh.** `git apply --check` refuses a patch that no longer applies, which was tested locally (re-apply and tampered-patch refusal). A real refresh is Phase 6.
