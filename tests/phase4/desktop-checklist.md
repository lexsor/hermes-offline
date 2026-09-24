# Phase 4 manual checklist: desktop and lifecycle cases

These cases need interaction with the UI, so `Invoke-Phase4.ps1` does not run them. Do them on the test VM **after** the automated run (P0–T6, T11), with the network still blocked. Save screenshots and notes to the run's evidence folder, named by case ID.

Before each case, write the local start time in the notes. Collect-NetworkEvidence attributes drops by time, and manual cases have no automatic timeline. Add them to `results.json` by hand or cite the times in the report.

## Setup

First, in a **separate** PowerShell window that stays open for all manual cases, start the process sampler. The automated run's sampler has stopped, and without this every network event during the manual cases has an unattributable PID:

```powershell
cd C:\OfflineHermes-src
powershell -ExecutionPolicy Bypass -File .\tests\phase4\Watch-Processes.ps1 -OutputCsv '<run evidence folder>\manual\processes-manual.csv'
```

Then, in a non-elevated PowerShell on the VM, with `<run evidence folder>\manual` as `$evidence` so the mock's files do not overwrite T6's:

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

## T8: desktop launched directly

1. Open a **new** Explorer window. Do not use the setup PowerShell, whose environment would leak into the app.
2. Double-click `%LOCALAPPDATA%\OfflineHermes\app\Hermes.exe`.
3. Record what happens and take screenshots. Save the process listing: `Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -match 'OfflineHermes|\\hermes\\' } | Select-Object ProcessId, ExecutablePath, CommandLine | Format-List`.
4. Close the app, and list `%LOCALAPPDATA%\hermes` if it exists.

**Pass (patch 0002):**
- The app starts like the launcher, with its backend under `%LOCALAPPDATA%\OfflineHermes\venv`.
- The home is the recorded offline home.
- No process runs from `%LOCALAPPDATA%\hermes`, and nothing new appears there.
- No install attempt and no public network events.

Before patch 0002 (Phase 4 runs 1–3), a direct launch ran without the offline environment: "Hermes couldn't start" with *Repair install*, and files written to `%LOCALAPPDATA%\hermes` (gaps G1/G2).

## T9: backend unavailable

The desktop starts its backend with the venv's Python, so disable the whole venv. Renaming `hermes.exe` isn't enough.

1. `Rename-Item "$install\venv" venv.phase4-disabled`
2. From the setup window, launch through `launch-hermes.cmd`, and record the behavior as in T8. Optionally click *Repair install* once.
3. Watch for installer children: `Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell|pwsh|git|python|uv|pip|curl' } | Select-Object ProcessId, Name, CommandLine`.
4. Restore: `Rename-Item "$install\venv.phase4-disabled" venv`, then rerun `.\scripts\verify-offline.ps1`.

**Pass (patch 0002):**
- A visible failure saying the Offline Hermes install can't start its backend and should be repaired offline with `scripts/install-offline.ps1 -Force`.
- *Repair install* only restarts the backend and shows the same message.
- No `install.ps1`, `git clone`, `pip`, `uv` or `curl` process.

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
# Stop the Watch-Processes window with Ctrl+C. Then, elevated, pointing at the RUN folder (not manual\):
$run = '<run evidence folder>'
.\tests\phase4\Collect-NetworkEvidence.ps1 -EvidenceDirectory $run -ProcessLog "$run\processes.csv,$run\manual\processes-manual.csv" -CaseTimeline "$run\results.json" -FailOnFindings
```

Manual cases have no entries in `results.json`, so their events are reported as `between-cases`. Use `manual\timeline.txt` to place them.
