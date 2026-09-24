# Phase 4 record run (run 3) on a used Azure VM

This is one sequence for the final, clean Phase 4 run on a VM that has already run earlier rounds. It resets the host, runs the automated cases and every manual case against the current code, then collects and exports the evidence. Test definitions are in [phase-4-validation-plan.md](phase-4-validation-plan.md); the first-time VM setup is in [phase-4-azure-runbook.md](phase-4-azure-runbook.md).

Keep the NSG outbound deny rule in place throughout. Use **Windows PowerShell** (`powershell.exe`) everywhere. Each stage says whether it needs an elevated window.

Expected time: about 30 minutes automated, 20 minutes for the T10 reinstall, and 15–20 minutes of other manual steps.

---

## Stage A: reset the host (elevated)

```powershell
cd C:\OfflineHermes-src

# A1. Stop anything left over from earlier runs.
Get-Process Hermes -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -match '\\OfflineHermes' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# A2. Bring every non-vendored folder up to the current commit (vendor/ and upstream/ are unchanged).
foreach ($d in 'scripts', 'tests', 'patches', 'manifests', 'config', 'docs') {
    robocopy "\\tsclient\C\#DEV\Offline_Hermes\$d" "C:\OfflineHermes-src\$d" /MIR /NFL /NDL /NJH /NP | Out-Null
    "synced $d (robocopy exit $LASTEXITCODE; below 8 is success)"
}
powershell -ExecutionPolicy Bypass -File .\scripts\verify-deps.ps1

# A3. Lift the old in-guest block (the NSG still denies Internet), so the run starts with a fresh one.
powershell -ExecutionPolicy Bypass -File .\tests\phase4\Disable-NetworkBlock.ps1

# A4. Remove everything earlier runs created. Run 1/2 evidence is already on the laptop.
$paths = @(
    "$env:LOCALAPPDATA\OfflineHermes", "$env:LOCALAPPDATA\OfflineHermes-home",
    "$env:LOCALAPPDATA\hermes", "$env:LOCALAPPDATA\npm-cache", "$env:LOCALAPPDATA\pip",
    "$env:LOCALAPPDATA\electron", "$env:LOCALAPPDATA\electron-builder",
    "$env:APPDATA\Hermes", "$env:TEMP\phase4-test-home", "C:\OfflineHermes-src\phase4-evidence"
) + @(Get-ChildItem $env:LOCALAPPDATA -Directory -Filter 'OfflineHermes.*' | ForEach-Object FullName) +
    @(Get-ChildItem $env:TEMP -Directory -Filter 'phase4-*' -ErrorAction SilentlyContinue | ForEach-Object FullName)
foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force; "removed $p" } }

# A5. Preview the P0 clean-host check. This must print nothing.
Import-Module .\tests\phase4\Phase4.psm1 -Force; Get-CleanHostFindings

# A6. Fresh block: new start time, 512 MB DNS log, self-verifying (expect 0/16 reached, loopback OK).
powershell -ExecutionPolicy Bypass -File .\tests\phase4\Enable-NetworkBlock.ps1 -IUnderstandThisBlocksAllOutboundTraffic
```

If A4 cannot remove `phase4-evidence` (an Explorer or Notepad window has it open), close those windows and rerun A4. If A5 prints anything, fix it before continuing.

---

## Stage B: process sampler for the whole run (Window A, non-admin, leave running)

```powershell
cd C:\OfflineHermes-src
powershell -ExecutionPolicy Bypass -File .\tests\phase4\Watch-Processes.ps1 -OutputCsv 'C:\OfflineHermes-src\phase4-run3-manual-processes.csv'
```

---

## Stage C: automated cases (Window B, non-admin)

```powershell
cd C:\OfflineHermes-src
powershell -ExecutionPolicy Bypass -File .\tests\phase4\Invoke-Phase4.ps1 -Cases P0,T1,T2,T3,T4,T5,T6,T11
```

Expect 8/8. T4 now also fails if the install leaves any host cache behind.

---

## Stage D: manual cases (Window B, non-admin)

```powershell
# D0. Setup
$run      = (Get-ChildItem .\phase4-evidence -Directory -Filter 'phase4-*' | Sort-Object Name | Select-Object -Last 1).FullName
$evidence = "$run\manual"; New-Item -ItemType Directory $evidence -Force | Out-Null
$install  = "$env:LOCALAPPDATA\OfflineHermes"
function Mark($t) { "$t $(Get-Date -Format o)" | Add-Content "$evidence\timeline.txt" }
$mock = .\tests\phase4\Start-MockProvider.ps1 -HermesHome "$env:TEMP\phase4-test-home" -EvidenceDirectory $evidence -NodeExe "$install\runtime\node\node.exe" | Select-Object -Last 1
$env:OFFLINE_HERMES_HOME = "$env:TEMP\phase4-test-home"
"run folder: $run"
```

### T7: desktop app via the launcher

```powershell
Mark 'T7 start'; cmd /c "$install\launch-hermes.cmd"
```

1. Wait for the window. Send `Run 3 smoke one`, confirm the mock's reply, and **wait a full minute**.
2. Save the process listing:
   ```powershell
   Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -match 'OfflineHermes' } | Select-Object ProcessId, ExecutablePath, CommandLine | Format-List | Out-File "$evidence\T7-processes.txt"
   ```
3. Open **Check for Updates** in the app menu and screenshot it as `$evidence\T7-updates.png`. It should say the app can't update itself because there's "no version-control metadata".
4. Quit, relaunch with `cmd /c "$install\launch-hermes.cmd"`, send `Run 3 smoke two`, confirm the reply, and quit again.
5. Record the prompts the mock received and close the case:
   ```powershell
   (Get-Content $mock.StateFile -Raw | ConvertFrom-Json).prompts | Out-File "$evidence\T7-mock-prompts.txt"
   Mark 'T7 end'
   ```

### T8: `Hermes.exe` opened directly

```powershell
Get-Process Hermes -ErrorAction SilentlyContinue    # must print nothing
Mark 'T8 start'
```

1. Open `C:\Users\azureuser\AppData\Local\OfflineHermes\app\` **in Explorer** and double-click `Hermes.exe`.
2. Wait a minute. With patch 0002 the app should start normally, using the offline home and the offline backend, exactly as through the launcher. That home has no provider configured, so the app may ask for one; don't configure it. Screenshot it as `$evidence\T8-screen.png`, and save a process listing:
   ```powershell
   Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -match 'OfflineHermes|\\hermes\\' } | Select-Object ProcessId, ExecutablePath, CommandLine | Format-List | Out-File "$evidence\T8-processes.txt"
   ```
3. Close the window, then:
   ```powershell
   Mark 'T8 end'
   Get-ChildItem "$env:LOCALAPPDATA\hermes" -Recurse -ErrorAction SilentlyContinue | Select-Object FullName, Length | Out-File "$evidence\T8-created.txt"
   ```

### T9: backend unavailable

With patch 0002, expect the app to show this Offline Hermes install can't start its backend and should be repaired offline with `scripts/install-offline.ps1 -Force`, and **not** offer to download Hermes. Clicking *Repair install* here should only restart the backend and show the same message.

The desktop app starts its backend with the venv's Python (`venv\Scripts\python.exe -m hermes_cli.main serve`), so disabling the whole venv is the real test. Renaming `hermes.exe` isn't.

```powershell
Get-Process Hermes -ErrorAction SilentlyContinue    # must print nothing
Rename-Item "$install\venv" venv.phase4-disabled
Mark 'T9 start'; cmd /c "$install\launch-hermes.cmd"
```

1. Wait a minute. Screenshot what the app shows as `$evidence\T9-screen.png`. Don't click install or repair.
2. While it's still open:
   ```powershell
   Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell|pwsh|git|python|uv|pip|node|curl' } | Select-Object ProcessId, Name, CommandLine | Format-List | Out-File "$evidence\T9-processes.txt"
   ```
3. Close the app, restore the venv, and verify:
   ```powershell
   Mark 'T9 end'
   Rename-Item "$install\venv.phase4-disabled" venv
   powershell -ExecutionPolicy Bypass -File .\scripts\verify-offline.ps1
   ```

### T12: a lazy install is refused

```powershell
Mark 'T12 start'
$env:HERMES_DISABLE_LAZY_INSTALLS = '1'; $env:HERMES_HOME = "$env:TEMP\phase4-test-home"
& "$install\venv\Scripts\python.exe" -c "from tools.lazy_deps import ensure, FeatureUnavailable`ntry:`n    ensure('tts.edge', prompt=False); print('UNEXPECTED: installed')`nexcept FeatureUnavailable as e:`n    print('refused:', e)" *>&1 | Tee-Object "$evidence\T12.txt"
Remove-Item Env:HERMES_DISABLE_LAZY_INSTALLS, Env:HERMES_HOME
Mark 'T12 end'
```

### T10: lifecycle

**T10a: reinstall with `-Force` keeps the home** (about 20 minutes). The mock provider runs from the install's own Node runtime and would lock the folder, so stop it first. No later case needs it.

```powershell
Stop-Process -Id $mock.ProcessId; Remove-Item Env:OFFLINE_HERMES_HOME
Get-Process Hermes -ErrorAction SilentlyContinue    # must print nothing
Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -match '\\OfflineHermes\\' } | Select-Object ProcessId, ExecutablePath   # must print nothing
Mark 'T10a start'
$before = (Get-FileHash "$env:LOCALAPPDATA\OfflineHermes-home\config.yaml").Hash
powershell -ExecutionPolicy Bypass -File .\scripts\install-offline.ps1 -Force *>&1 | Tee-Object "$evidence\T10a-install.log"
"config unchanged: $($before -eq (Get-FileHash "$env:LOCALAPPDATA\OfflineHermes-home\config.yaml").Hash)" | Tee-Object "$evidence\T10a-checks.txt"
Get-ChildItem $env:LOCALAPPDATA -Directory -Filter 'OfflineHermes.previous-*' | ForEach-Object Name | Tee-Object "$evidence\T10a-checks.txt" -Append
powershell -ExecutionPolicy Bypass -File .\scripts\verify-offline.ps1 *>&1 | Tee-Object "$evidence\T10a-checks.txt" -Append
Mark 'T10a end'
```

**T10b: a failed replacement leaves the install untouched.** This runs a scratch copy of the installer whose vendored files include one corrupted wheel:

```powershell
Mark 'T10b start'
$scratch = 'C:\t10b-scratch'
foreach ($d in 'vendor', 'manifests', 'scripts', 'patches') { robocopy "C:\OfflineHermes-src\$d" "$scratch\$d" /E /NFL /NDL /NJH /NP | Out-Null }
$wheel = Get-ChildItem "$scratch\vendor\python\windows-x64-cp311\*.whl" | Select-Object -First 1
$bytes = [IO.File]::ReadAllBytes($wheel.FullName); $bytes[1024] = $bytes[1024] -bxor 0xFF; [IO.File]::WriteAllBytes($wheel.FullName, $bytes)
$backupsBefore = @(Get-ChildItem $env:LOCALAPPDATA -Directory -Filter 'OfflineHermes.previous-*').Count
powershell -ExecutionPolicy Bypass -File "$scratch\scripts\install-offline.ps1" -Force *>&1 | Tee-Object "$evidence\T10b-install.log"
"installer exit: $LASTEXITCODE (expect 1)" | Tee-Object "$evidence\T10b-checks.txt"
"backups before/after: $backupsBefore/$(@(Get-ChildItem $env:LOCALAPPDATA -Directory -Filter 'OfflineHermes.previous-*').Count) (expect equal)" | Tee-Object "$evidence\T10b-checks.txt" -Append
powershell -ExecutionPolicy Bypass -File .\scripts\verify-offline.ps1 *>&1 | Tee-Object "$evidence\T10b-checks.txt" -Append
Remove-Item $scratch -Recurse -Force
Mark 'T10b end'
```

T10c, the uninstall footprint, comes after evidence collection in Stage F, because it deletes the install.

### D-end: record the run folder

The mock provider was already stopped before T10a.

```powershell
"$run" | Set-Content C:\OfflineHermes-src\phase4-run3-folder.txt
```

Then press **Ctrl+C in Window A** to stop the sampler.

---

## Stage E: collect the network evidence (elevated)

```powershell
cd C:\OfflineHermes-src
$run = Get-Content C:\OfflineHermes-src\phase4-run3-folder.txt
Move-Item C:\OfflineHermes-src\phase4-run3-manual-processes.csv "$run\manual\processes-manual.csv"
powershell -ExecutionPolicy Bypass -File .\tests\phase4\Collect-NetworkEvidence.ps1 -EvidenceDirectory $run -ProcessLog "$run\processes.csv,$run\manual\processes-manual.csv" -CaseTimeline "$run\results.json" -FailOnFindings
powershell -ExecutionPolicy Bypass -File .\tests\phase4\Assert-NetworkBlocked.ps1 *>&1 | Tee-Object "$run\final-network-probe.txt"
```

What to expect:

| Collector line | Expected |
|---|---|
| `firewall log` and `DNS log` | Both `read` |
| `Hermes/test processes` | `0 public drops, 0 public DNS queries`, except any lookups from the T8 window (the expected gap) |
| `wpad` from `Hermes.exe` | Local, not counted as public |

---

## Stage F: uninstall footprint (T10c), then export (non-admin, then elevated)

```powershell
# non-admin
$run = Get-Content C:\OfflineHermes-src\phase4-run3-folder.txt
"T10c start $(Get-Date -Format o)" | Add-Content "$run\manual\timeline.txt"
Remove-Item "$env:LOCALAPPDATA\OfflineHermes", "$env:LOCALAPPDATA\OfflineHermes-home" -Recurse -Force
Get-ChildItem $env:LOCALAPPDATA -Directory -Filter 'OfflineHermes.previous-*' | Remove-Item -Recurse -Force
@("$env:LOCALAPPDATA", "$env:APPDATA", "$env:TEMP") | ForEach-Object { Get-ChildItem $_ -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'hermes|electron|npm|pip|uv|phase4' } | Select-Object FullName, LastWriteTime } | Format-Table -AutoSize | Out-String -Width 220 | Tee-Object "$run\manual\T10c-leftovers.txt"
"T10c end $(Get-Date -Format o)" | Add-Content "$run\manual\timeline.txt"
```

Expected leftovers with patch 0002: only `%TEMP%\phase4-test-home`, the harness's mock home. The desktop's Electron user data is now inside each Hermes home (`desktop-user-data\`), so it's removed with the home.

Before patch 0002, runs also left `%APPDATA%\Hermes` and, after a T8 direct launch, `%LOCALAPPDATA%\hermes`. Either of those appearing now is a finding, as is anything else.

```powershell
# elevated
$run = Get-Content C:\OfflineHermes-src\phase4-run3-folder.txt
$dest = '\\tsclient\C\#DEV\Offline_Hermes\phase4-evidence'
robocopy C:\OfflineHermes-src\phase4-evidence $dest /E /NFL /NDL /NJH /NP
New-Item -ItemType Directory "$dest\vm-context" -Force | Out-Null
Copy-Item C:\ProgramData\OfflineHermesPhase4\state.json "$dest\vm-context\state-run3.json" -Force
"run 3 folder: $(Split-Path $run -Leaf)"
```

Report back the run folder name, the Stage C results table, the Stage E collector output, and anything unexpected on screen.
