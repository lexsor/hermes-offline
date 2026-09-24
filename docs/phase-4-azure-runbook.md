# Phase 4 on an Azure Windows 11 VM

For the final clean run on a VM that already ran earlier rounds, use [phase-4-record-run.md](phase-4-record-run.md).

A step-by-step runbook for the network-blocked validation on an Azure VM instead of the Hyper-V VM in `tests/phase4/New-Phase4Vm.ps1`. The test cases and pass criteria are in [phase-4-validation-plan.md](phase-4-validation-plan.md).

On Azure you reach the VM over RDP, so the network block must never cut the RDP session:

- The **outer layer** is an Azure NSG outbound deny. It can be reversed from the portal even if the VM is unreachable.
- The **inner layer** is `Enable-NetworkBlock.ps1` inside the VM, **without** `-AlsoRemoveRoutesAndDns`. The script refuses that option on Azure.
- The NSG alone is not enough, because it does not block Azure's platform DNS (`168.63.129.16`). The in-guest block does.

Every command below runs in **Windows PowerShell** (`powershell.exe`), because a clean VM does not have PowerShell 7. Windows 11's default execution policy blocks scripts, so each script call uses `-ExecutionPolicy Bypass -File`.

## 0. Azure portal, before you start

1. VM size: at least 4 vCPU and 16 GB RAM (for example `Standard_D4s_v5`). OS disk: 128 GB.
2. **Enable boot diagnostics and Serial Console** (VM → Help → Boot diagnostics / Serial console). This is your way back in if RDP drops.
3. The NSG inbound rules allow RDP (3389) from **your IP only**.

## 1. Prepare the VM (online)

RDP in, then:

1. **Install Git for Windows**, which includes Git LFS. This is the only thing installed from the Internet, and it is removed again in step 1.5.
2. **Enable long paths.** In an elevated PowerShell:
   ```powershell
   Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value 1 -Type DWord
   ```
3. **Clone with the LFS content** (non-elevated PowerShell):
   ```powershell
   git clone https://github.com/lexsor/hermes-offline.git C:\hermes-clone
   cd C:\hermes-clone
   git lfs pull
   powershell -ExecutionPolicy Bypass -File .\scripts\verify-deps.ps1
   ```
   The last command must report `Verified 1110 vendored files`. If it reports a checksum mismatch, the LFS files did not download; rerun `git lfs pull`.
4. **Export a clean tree without `.git`.** This is what gets tested:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tests\phase4\New-Phase4Vm.ps1 -Stage Export -ExportDirectory C:\phase4-export
   tar -xf C:\phase4-export\OfflineHermes-src.tar -C C:\
   ```
   This creates `C:\OfflineHermes-src`. Keep `C:\phase4-export\OfflineHermes-src.tar.manifest.json`, which records the commit and tar SHA-256 for the report.
5. **Leave the host clean.** The P0 preflight fails if tools or caches that could hide a missing artifact are present.
   ```powershell
   cd C:\
   Remove-Item C:\hermes-clone, C:\phase4-export\OfflineHermes-src.tar -Recurse -Force
   ```
   Then uninstall **Git** in Settings → Apps. Open a new PowerShell and confirm that `git` is no longer found.
6. *(Recommended)* In the portal, **snapshot the OS disk**. Swapping back to it gives you a clean rerun, like the plan's `S1-staged`.

## 2. Cut connectivity

1. **NSG outbound deny** (portal → VM → Networking → Outbound port rules → Add):
   - Destination: Service Tag `Internet`
   - Ports: `*`, protocol Any
   - Action: **Deny**
   - Priority: `100`
   - Name: `phase4-deny-internet`

   NSGs are stateful, so your existing RDP session keeps working.
2. **In-guest block.** In an **elevated** PowerShell:
   ```powershell
   cd C:\OfflineHermes-src
   powershell -ExecutionPolicy Bypass -File .\tests\phase4\Enable-NetworkBlock.ps1 -IUnderstandThisBlocksAllOutboundTraffic
   ```
   It finishes by running the network check itself, which must end with `Network block verified: 0/16 public probes reached; loopback OK.`

   Expected side effects: the portal shows the VM agent as **Not Ready**, and Run Command stops working. Both come back when the block is removed.
3. **If RDP drops:** open Serial Console, then enter `cmd`, `ch -si 1` and sign in. Then run:
   ```
   powershell -ExecutionPolicy Bypass -File C:\OfflineHermes-src\tests\phase4\Disable-NetworkBlock.ps1
   ```
   Tell me what happened: it means the firewall's stateful exemption for RDP didn't hold on this image.

## 3. Automated tests

In a **non-elevated** PowerShell. They take about 20–30 minutes; the install is most of it.

```powershell
cd C:\OfflineHermes-src
powershell -ExecutionPolicy Bypass -File .\tests\phase4\Invoke-Phase4.ps1 -Cases P0,T1,T2,T3,T4,T5,T6,T11
```

- The results table prints at the end. The evidence goes to `C:\OfflineHermes-src\phase4-evidence\phase4-<timestamp>\` (`summary.md`, `results.json`, and a log per case).
- **P0 fails:** read its notes. Each line names the tool, cache or setting that makes the host "not clean". Fix it, delete `%LOCALAPPDATA%\OfflineHermes` and `%LOCALAPPDATA%\OfflineHermes-home` if T4 already ran, and rerun.
- **T4 fails with "Install root already exists":** an earlier run installed already. Delete the two folders above and rerun.

## 4. Manual cases (T7–T10, T12)

Follow [tests/phase4/desktop-checklist.md](../tests/phase4/desktop-checklist.md) with the network still blocked:

- **T7:** desktop app via `launch-hermes.cmd` against the mock provider.
- **T8:** `Hermes.exe` opened directly. This is expected to show a gap; record what happens.
- **T9:** backend missing.
- **T10:** reinstall, rollback and uninstall.
- **T12:** lazy-install refusal.

Save screenshots into the run's evidence folder.

## 5. Collect network evidence

In an **elevated** PowerShell, replacing `<run>` with the run folder name:

```powershell
cd C:\OfflineHermes-src
$run = "C:\OfflineHermes-src\phase4-evidence\<run>"
powershell -ExecutionPolicy Bypass -File .\tests\phase4\Collect-NetworkEvidence.ps1 -EvidenceDirectory $run -ProcessLog "$run\processes.csv" -CaseTimeline "$run\results.json" -FailOnFindings
powershell -ExecutionPolicy Bypass -File .\tests\phase4\Assert-NetworkBlocked.ps1
```

The first command must report `Public-destination drops: 0` and `public-name DNS queries: 0`; anything else lists the process and destination. The second confirms the block still held at the end.

## 6. Get the evidence out, still offline

**Direct RDP:** reconnect with **Local Resources → More → Drives** ticked, then copy the run folder to `\\tsclient\C\...` on your machine. That goes over the RDP connection, not the VM's network.

**Azure Bastion, Standard or Premium tier:** the browser session cannot share drives, but your own Remote Desktop client can, through a Bastion tunnel.
1. Tick Bastion → Configuration → **Native client support** once. Or run `az network bastion update --name <bastion> --resource-group <rg> --enable-tunneling true`.
2. On your laptop (Azure CLI, `az extension add --name bastion`):
   ```bash
   az network bastion tunnel --name <bastion> --resource-group <rg> --target-resource-id <vm-resource-id> --resource-port 3389 --port 55000
   ```
3. Connect `mstsc` to `localhost:55000` with Drives → C: ticked, then copy to `\\tsclient\C\...` as above. The block and NSG stay in place.

**Azure Bastion, Basic or Developer tier (browser only, text clipboard):**
- During testing, open `summary.md`, `network-evidence.json` and any failing `<case>.log` in Notepad, and paste their text out.
- For the full folder, wait until sections 3–5 are **complete**, because the evidence is captured by then:
  1. Zip it: `Compress-Archive <run folder> C:\phase4-evidence.zip`.
  2. Restore connectivity (section 7).
  3. Upload the zip from the VM, for example to a storage account container through the portal.
  4. Swap the OS disk back to the snapshot before any rerun, since the host is no longer clean.

Send me the folder, or `summary.md` and `network-evidence.json` at minimum, and I'll write the four Phase 4 reports from it.

## 7. Reset or finish

- **Rerun from clean:** swap the OS disk back to the snapshot from step 1.6. Or remove `%LOCALAPPDATA%\OfflineHermes*` and rerun section 3 (not a fully clean host).
- **Restore connectivity:**
  1. In an elevated PowerShell: `powershell -ExecutionPolicy Bypass -File C:\OfflineHermes-src\tests\phase4\Disable-NetworkBlock.ps1`
  2. Delete the `phase4-deny-internet` NSG rule.
