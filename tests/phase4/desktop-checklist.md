# Phase 4 manual checklist: desktop and lifecycle cases

These cases need interaction with the UI, so `Invoke-Phase4.ps1` does not run them. Do them on the test VM **after** the automated run (P0–T6, T11), with the network still blocked. Save screenshots and notes to the run's evidence folder, named by case ID.

Before each case, write the local start time in the notes. Collect-NetworkEvidence attributes drops by time, and manual cases have no automatic timeline. Add them to `results.json` by hand or cite the times in the report.

## Setup

In a non-elevated PowerShell on the VM:

```powershell
$evidence = '<run evidence folder>'
$install  = "$env:LOCALAPPDATA\OfflineHermes"
$testHome = "$env:TEMP\phase4-test-home"
$mock = .\tests\phase4\Start-MockProvider.ps1 -HermesHome $testHome -EvidenceDirectory $evidence -NodeExe "$install\runtime\node\node.exe" | Select-Object -Last 1
$env:OFFLINE_HERMES_HOME = $testHome   # the launchers use this home instead of the recorded one
```

Keep this window open. Anything launched from it inherits `OFFLINE_HERMES_HOME`.

## T7: desktop smoke via the launcher

1. From the setup window: `cmd /c "$install\launch-hermes.cmd"`.
2. Wait for the main window. Screenshot the first-run or boot screen.
3. Confirm the backend is the offline venv:
   `Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'hermes' } | Select-Object ProcessId, ExecutablePath, CommandLine | Format-List`.
   Expect the Python process under `$install\venv\Scripts\` and nothing under `%LOCALAPPDATA%\hermes`.
4. Send a chat message: `Phase 4 desktop smoke one`. Expect the mock reply ("Hello from the mock inference server! …"). Screenshot it.
5. Open the update panel (menu → Check for Updates). Expect the "can't update itself from inside the app / no version-control metadata" message, **not** a fetch error. Screenshot it.
6. Quit the app. Relaunch through the launcher, send `Phase 4 desktop smoke two`, and confirm the reply. Quit.
7. `Get-Content $mock.StateFile | ConvertFrom-Json | Select-Object -ExpandProperty prompts` must contain both messages.

**Pass:** both chats answered, the backend path is correct, and the update panel shows the not-a-git-checkout message. No public-network events in the T7 window.

## T8: desktop launched directly (expected gap)

1. Open a **new** Explorer window. Do not use the setup PowerShell, whose environment would leak into the app.
2. Double-click `%LOCALAPPDATA%\OfflineHermes\app\Hermes.exe`.
3. Record what happens: the boot screen text, any "installing" or "setting up" progress, and error dialogs. Take screenshots.
4. Watch for installer children: `Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell|pwsh|git|python|uv|pip' } | Select-Object ProcessId, Name, CommandLine`.
5. Close the app. If a bootstrap started, let it fail, and note whether it left files in `%LOCALAPPDATA%\hermes`.

**Pass:** a clear offline or unavailable error with no install attempt.
**Expected actual behavior:** upstream's first-run bootstrap starts, because without the launcher `HERMES_HOME` and `HERMES_DESKTOP_HERMES` are unset (`resolveHermesBackend` in `apps/desktop/electron/main.ts`). Record it as a gap with the observed behavior.

## T9: backend unavailable (expected gap)

1. `Rename-Item "$install\venv\Scripts\hermes.exe" hermes.exe.phase4-disabled`
2. From the setup window, launch through `launch-hermes.cmd`. Record the behavior as in T8, steps 3–5.
3. Restore: `Rename-Item "$install\venv\Scripts\hermes.exe.phase4-disabled" hermes.exe`, then rerun `.\scripts\verify-offline.ps1`.

**Pass:** a visible failure with no `install.ps1`, `git clone`, `pip` or `uv` process.

## T10: lifecycle

1. **Home survives reinstall.** Hash the home config:
   `Get-FileHash "$env:LOCALAPPDATA\OfflineHermes-home\config.yaml"`.
   Run `.\scripts\install-offline.ps1 -Force`. Then:
   - a `OfflineHermes.previous-*` backup exists;
   - the config hash is unchanged;
   - `verify-offline.ps1` passes.
2. **Failed replacement rolls back.** On a scratch copy of the repository (never the real one), replace one wheel with a same-named file of different content. Run the scratch copy's `install-offline.ps1 -Force` against the real install root. Expect: verification fails before anything moves, and the existing install is untouched (`verify-offline.ps1` still passes).

   To exercise the post-move rollback as well, make the venv step fail: temporarily deny read access to one wheel after verification. That needs a debugger breakpoint or a patched copy of the script, so treat it as optional. Record which variant you ran.
3. **Uninstall footprint.** Remove the install root, its `.previous-*` backups and `OfflineHermes-home`. Compare `%LOCALAPPDATA%`, `%APPDATA%` and `%TEMP%` against the `S1-staged` snapshot listing (`Get-ChildItem -Force` at each root). List everything left behind. Electron user data (`%APPDATA%\Hermes` or similar) is expected; record its path.

## T12: lazy-install refusal

1. Start Process Monitor with a filter on process names `pip.exe`, `uv.exe`, `uvx.exe`, `npm*`, `npx*` and `git.exe`, operation Process Create.
2. Through `hermes-offline.cmd`, use one feature whose optional dependency is outside the profile: a voice or TTS toolset, browser automation, or a messaging platform. Record the exact command.
3. **Pass:** Hermes reports the feature as unavailable or not installed, Process Monitor shows no package-manager process, and there are no public-network events.

## After the manual cases

```powershell
Stop-Process -Id $mock.ProcessId
Remove-Item Env:OFFLINE_HERMES_HOME
# elevated:
.\tests\phase4\Collect-NetworkEvidence.ps1 -EvidenceDirectory $evidence -ProcessLog "$evidence\processes.csv" -CaseTimeline "$evidence\results.json" -FailOnFindings
```

The process sampler only runs during `Invoke-Phase4.ps1`. For drops during manual cases, the `pid` column plus your screenshots and process listings are the attribution evidence.
