# Phase 4: offline runtime smoke test

**Result: pass, with documented gaps.** With public outbound networking blocked, both the CLI and the desktop app completed chats against a loopback inference provider. No Hermes process attempted public network access in any test case. The remaining issues concern a *direct* launch of `Hermes.exe`, which bypasses the launcher; see [final-gap-list.md](final-gap-list.md).

Record run: `phase4-20260924-180727` on the Azure VM described in [offline-install-test.md](offline-install-test.md).

## Inference provider

`tests/phase4/Start-MockProvider.ps1` runs upstream's own OpenAI-compatible mock (`tests-js/scripts/mock-server.ts`, Node built-ins only) under the **bundled** Node runtime, listening on `127.0.0.1`. It writes a harness-only Hermes home (`%TEMP%\phase4-test-home`) that points at the mock. The launchers select that home through `OFFLINE_HERMES_HOME`. The mock does not simulate tool calls, so these cases prove the chain boot → backend → inference → UI, not tool execution.

## Results

| Case | What was done | Result |
|---|---|---|
| **T6** CLI | `hermes-offline.cmd -z "Phase 4 smoke: say hello"` | **Pass**: the mock's reply was printed, and the mock received the prompt |
| **T7** desktop via `launch-hermes.cmd` | Two launches, one chat each, with a one-minute idle on the first; process listing; Check for Updates | **Pass** (details below) |
| **T8** `Hermes.exe` opened from Explorer | Launched without the launcher's environment; no buttons clicked | **Gap G1/G2**: "Hermes couldn't start: background service didn't answer in time", with *Retry / Repair install / Gateway settings*. No automatic install or network attempt, but it created `%LOCALAPPDATA%\hermes\desktop-plugins` and `logs\desktop.log` |
| **T9** backend unavailable | `venv` folder renamed, then launched via the launcher | **Pass**: "Hermes couldn't start: … Cannot own a backend without a complete process identity". No installer, Git, pip or uv process (`T9-processes.txt`). The same *Repair install* caveat applies (G2) |
| **T12** lazy install | `tools.lazy_deps.ensure('tts.edge')` with `HERMES_DISABLE_LAZY_INSTALLS=1` | **Pass**: `refused: Feature 'tts.edge' unavailable: lazy installs disabled…`. No pip or uv process |

**T7 in detail:**
- **Backend:** the backend was the offline venv, `venv\Scripts\python.exe -m hermes_cli.main serve --host 127.0.0.1 --port 0`, with the bundled runtime Python beneath it, five `app\Hermes.exe` processes, and the mock's `runtime\node\node.exe`. Nothing ran from the online-install location `%LOCALAPPDATA%\hermes`.
- **Chats:** both reached the mock. It received `Run 3 smoke one` (recorded twice, which is an auxiliary request per chat that upstream makes) and `Run 3 smoke two`.
- **Update panel** (screenshot `T7-updates.png`): "This copy of Hermes can't update itself from inside the app … `…\phase4-test-home\hermes-agent` has no version-control metadata." The desktop's own GitHub update check stops before any request.

### Network attempts per case

Both logs covered the whole run, from the first case onward, and every in-case event was attributed.

| Case | Hermes / tool processes | Unattributed | Host background (blocked) |
|---|---:|---:|---:|
| T6 CLI chat | **0** | 0 | 268 |
| T7 desktop | **0** | 0 | 1923 |
| T8 direct launch | **0** | 0 | 315 |
| T9 backend unavailable | **0** | 0 | 287 |
| T12 lazy install | **0** | 0 | 8 |

The only lookups by a Hermes process were `wpad` from `Hermes.exe`'s network service (24 in total across the run): a **local-name** proxy auto-discovery query, not public traffic (gap G3). The desktop tried no other names.

## Offline behavior that Phase 4 had to fix

Each of these was found by the harness on this VM, fixed, and then shown absent in run 3.

| Found in | Behavior | Fix |
|---|---|---|
| Phase 3 | `hermes --version` ran a passive update check against `api.github.com`, using the host's online Hermes home | A dedicated `OfflineHermes-home` seeded with `updates.check: false`; launchers pin `HERMES_HOME` |
| Run 2, T7 | The default desktop theme injected a Google Fonts stylesheet on every start: 8 blocked DNS queries sent directly by `Hermes.exe` | `patches/0001-desktop-no-remote-theme-fonts.patch`. Run 2's T7b recheck and all of run 3 show 0 |
| Run 2, T7b/T9 | The desktop backend fetched the model catalog (`hermes-agent.nousresearch.com`, then `raw.githubusercontent.com`) and `models.dev` on every start: 18 lookups per launch | Seeded config `model_catalog.enabled: false` and `models_dev.url` pointed at a closed loopback port. `verify-offline` enforces both. Run 2's T7c recheck and all of run 3 show 0 |

**The cost of that last fix:** offline, the desktop has no per-provider model lists and no models.dev metadata. For a local provider, set the model name and `context_length` in the Hermes home's config (see `docs/configuration.md`).

## Not covered here

- **Tool execution:** the mock provider doesn't issue tool calls.
- **External local services** (Honcho, MCP servers, a real local model server): configuration examples exist, but no service was run (gap G9).
- **Features outside the profile** (browser automation, voice, messaging bridges): these fail as unavailable, as shown for TTS in T12. They weren't exercised individually.
