# Phase 4: final gap list

These are the known gaps and exceptions after network-blocked validation (record run `phase4-20260924-180727`). Each entry gives the reason, the owner action and what the user sees. The **severity** column concerns the offline guarantee: none of these involves an observed public network attempt by Hermes during validation.

## Gaps

| ID | Gap | Severity | What the user sees | Owner action |
|---|---|---|---|---|
| **G1** | **Opening `app\Hermes.exe` directly** bypasses `launch-hermes.cmd`, so it runs without the offline `HERMES_HOME`, `HERMES_DESKTOP_HERMES` and PATH. The desktop resolves the upstream default home `%LOCALAPPDATA%\hermes` and writes `desktop-plugins\` and `logs\desktop.log` there. On a host with an online Hermes install or a user-level `HERMES_HOME`, it would attach to *that* install instead. | Medium | T8: "Hermes couldn't start: background service didn't answer in time". No network attempt. | Phase 5: installer shortcuts point only at `launch-hermes.cmd`. Decide whether also to patch the desktop to default to the offline home when `install-state.json` sits beside it. |
| **G2** | **"Repair install" / "Install Hermes locally"** buttons (T8, T9, and run 2's first-run screen) start upstream's networked bootstrap installer. | Medium | Not clicked during validation. Offline it can only fail, and how visibly is untested. With network access it would install an *online* Hermes into `%LOCALAPPDATA%\hermes`. | Decide: patch the desktop to hide or disable bootstrap and repair in the offline profile (preferred), or document it. Test the offline click in Phase 5 either way. |
| **G3** | **WPAD proxy auto-discovery**: `Hermes.exe`'s network service looks up the single-label name `wpad` (24 lookups in run 3). | Low | Nothing visible. The name is local, not public, but on a corporate LAN it can reach an internal WPAD server. | Optional: have the launcher pass Electron `--no-proxy-server`, or document it. Keep system proxy behavior for users who need a LAN proxy to reach their model server. |
| **G4** | **Model catalog and models.dev disabled offline** (`model_catalog.enabled: false`, loopback `models_dev.url`). | Low (functional) | The desktop shows no per-provider model lists and no registry metadata such as context sizes and pricing. | Documented in `docs/configuration.md`. Users set the model name and `context_length` for local models. A later option is to vendor a catalog snapshot and serve it locally. |
| **G5** | **Hermes homes created before commit `224f6f5`** lack the catalog settings. The installer never overwrites a user's `config.yaml`. | Low | The installer prints a warning with the lines to add; `verify-offline` fails until they are added. | Documented. No further action. |
| **G6** | **Uninstall residue**: removing the install root and home leaves `%APPDATA%\Hermes` (Electron user data), plus `%LOCALAPPDATA%\hermes` after any direct launch (G1). There is no uninstaller yet. | Low | Leftover folders (T10c). | Phase 5: an uninstaller, or documented uninstall steps covering both paths. |
| **G7** | **`scripts\build-bundle.ps1` produces a non-relocatable archive**: it zips an installed tree whose venv and launchers embed its temporary path. | Medium (Phase 5) | The bundle works only at the path it was built at. | Phase 5: ship the repository plus installer, or make the venv relocatable. Don't publish `build-bundle` output as it stands. |
| **G8** | **No standard-user validation run**: run 3's automated cases ran elevated. Runs 1–2 ran them from a non-elevated window, but on earlier code. | Low | None expected (same user profile). | Repeat Stage C (and ideally T7) as a standard user before release. |
| **G9** | **Not exercised**: tool execution (the mock issues no tool calls), a real local model server, and Honcho or MCP servers. | Medium (coverage) | n/a | Phase 5 smoke: a local OpenAI-compatible server (for example llama.cpp or vLLM) on loopback or LAN, and one MCP server configured through `config/mcps.example.yaml`, with the same network evidence collection. |
| **G10** | **`Invoke-CheckedCommand` does not escape a trailing backslash inside a quoted argument.** No current call site hits this. | Low | A command could fail on install paths containing spaces that end in `\`. | Fix when next touching `scripts/lib/OfflineHermes.psm1`. |
| **G11** | **Supply chain and legal**: artifacts are checksum-pinned but not signature-verified against upstream publishers, and `manifests/licenses.lock` records that human legal/compliance approval is required before public redistribution. | High (release gate) | n/a | Legal review before any public release. Phase 6: record signatures and provenance where publishers provide them. |
| **G12** | **On-demand remote content**: some features reach the network only when used, for example social-media embeds in chat (`social-embed.tsx` loads a remote script), web links, the skills hub, the plugin catalog and the browser tool. | Low | The feature fails or shows nothing offline; the firewall blocks it. | Documented. Not audited individually; add to the Phase 6 network-surface diff. |
| **G13** | **Other platforms**: the gateway's `tirith` security scanner downloads a binary on first use where a build exists. It is silent on Windows. | n/a for this profile | n/a | Handle it when a Linux or macOS profile is added. |
| **G14** | **Windows 10** is claimed by the profile but was not tested (validated on Windows 11 Pro 26200). The Hyper-V stages of `tests/phase4/New-Phase4Vm.ps1` were not exercised (the Azure path was used). | Medium (coverage) | n/a | Run the record-run sequence once on Windows 10 22H2, or narrow the claim to Windows 11. |
| **G15** | **Upstream message**: with `HERMES_DISABLE_LAZY_INSTALLS=1`, the lazy-install refusal names `security.allow_lazy_installs=false` as the reason. | Cosmetic | A misleading reason text (T12). | Optional upstream report. |
| **G16** | **Upstream secret-scan hits not fully reviewed**: T11 found 0 hits in the distribution's own files, and 107 key-like strings in `upstream/` (test fixtures, skill docs). Only a sample was inspected. | Low | n/a | Review `T11-upstream-hits.txt` in full before release. Upstream content is unmodified and public, but the release should not ship a live credential. |

## Acceptance checklist (`ACCEPTANCE_TESTS.md`)

| Item | Status |
|---|---|
| Phase 1 reports complete | Done |
| Upstream source preserved with minimal modifications | Done: byte-identical tree `8196c19`; one reviewed patch applied at install |
| All required redistributable dependencies vendored | Done: 1110 checksummed files |
| Manifests and checksums generated | Done |
| Offline installer created | Done |
| Missing-artifact failure tested | Done (T3) |
| Checksum failure tested | Done (T2, T10b) |
| Outbound network disabled during validation | Done: NSG plus in-guest firewall, 0/16 probes at start and end |
| Offline install tested from a clean environment | Done (P0 clean, T4) |
| Smoke test documented and passing | Done (T6, T7), with G1/G2 documented |
| Secrets absent from Git | Done for distribution files (T11: 0 hits). The 107 upstream hits are listed in `T11-upstream-hits.txt`; a sample were test fixtures and docs, and the full list still needs a manual review (G16) |
| Redistribution exceptions documented | Done (`reports/redistribution-exceptions.md`), pending legal review (G11) |
| Upstream update workflow documented and tested | **Not started** (Phase 6) |

Phase 4 is complete. The project as a whole is not, per `AGENTS.md`: Phase 5 (distribution) and Phase 6 (the upstream update workflow) remain, and G1, G2, G7 and G11 must be resolved before a release.
