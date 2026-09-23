# Phase 4 harness

Network-blocked validation for the `windows-x64-desktop` profile. The plan, test-case definitions and exit criteria are in [docs/phase-4-validation-plan.md](../../docs/phase-4-validation-plan.md).

**Run this only on a disposable Windows x64 VM.** `Enable-NetworkBlock.ps1` blocks every non-loopback outbound connection. It refuses to run unless it is elevated, the machine looks like a VM, and `-IUnderstandThisBlocksAllOutboundTraffic` is passed.

| Script | Elevated | Purpose |
|---|---|---|
| `Enable-NetworkBlock.ps1` | yes | Exports the firewall policy, then sets default-deny outbound. Disables built-in outbound allow rules, adds a block rule for all non-loopback addresses, and enables drop and DNS logging. `-AlsoRemoveRoutesAndDns` adds a second layer. Verifies the block when done. |
| `Disable-NetworkBlock.ps1` | yes | Re-imports the exported policy and restores routes and DNS. Reverting the VM snapshot is just as good. |
| `Assert-NetworkBlocked.ps1` | no | 16 public probes (system DNS, direct DNS, HTTPS, raw TCP v4/v6) must all fail, and loopback must work. `-ExpectOpen` inverts this to validate the harness on a connected machine. |
| `Invoke-Phase4.ps1` | no | Runs P0–T6 and T11 unattended. Each case runs in a child `pwsh` with a full transcript and timing, while a process sampler records PID-to-image mappings. Writes `results.json`, `summary.md`, and the transcripts. |
| `Collect-NetworkEvidence.ps1` | yes | Parses `pfirewall.log` and the DNS client log since the block was enabled. Classifies destinations, names processes from the sampler, attributes each event to a case (`-CaseTimeline`), and fails with `-FailOnFindings` if anything public was attempted or the evidence is incomplete. |
| `Start-MockProvider.ps1` | no | Starts upstream's stdlib-only OpenAI-compatible mock on 127.0.0.1 under the bundled Node, and writes a marked test Hermes home pointing at it. |
| `New-Phase4Vm.ps1` | host, yes (except `Export`) | Builds and manages the Hyper-V test VM in stages: `Create`, then `Isolate` (private switch, `S0-clean`), then `Stage` (repository copied in over PowerShell Direct, block enabled, `S1-staged`), then `Reset` / `CollectEvidence` between runs. `Export` alone needs no admin or Hyper-V. |
| `desktop-checklist.md` | — | Manual cases T7–T10 and T12. |
| `static-checks.sh` | — | File presence, the no-public-URL rule, the safety interlocks, and PowerShell parse checks. |

## Building the VM (Hyper-V host)

Enable Hyper-V once on the host (elevated, then reboot): `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All`. Then:

```powershell
# elevated, on the host
.\tests\phase4\New-Phase4Vm.ps1 -Stage Create -IsoPath <Windows 11 x64 ISO you supply>
#   install Windows in the VM console (local admin account), apply all updates
.\tests\phase4\New-Phase4Vm.ps1 -Stage Isolate   # private switch, long paths, preflight, S0-clean
.\tests\phase4\New-Phase4Vm.ps1 -Stage Stage     # export, copy over VMBus, verify, block, S1-staged
```

After `Isolate`, the VM's only network adapter is on a Private switch. The repository reaches it over PowerShell Direct, never over a network. `Stage` refuses to run while any adapter is on another switch. Between runs, `-Stage Reset` restores `S1-staged`, and `-Stage CollectEvidence` copies `phase4-evidence` back to the host.

A clean guest has only **Windows PowerShell 5.1**; PowerShell 7 is not vendored. The harness and the offline installer must work under 5.1, so run everything in the VM with `powershell.exe`.

## Run order on the VM

```powershell
# New-Phase4Vm.ps1 -Stage Stage has already enabled the block. Otherwise, elevated:
# .\tests\phase4\Enable-NetworkBlock.ps1 -IUnderstandThisBlocksAllOutboundTraffic -AlsoRemoveRoutesAndDns

# standard user
.\tests\phase4\Invoke-Phase4.ps1 -Cases P0,T1,T2,T3,T4,T5,T6,T11
# then the manual cases in desktop-checklist.md

# elevated
.\tests\phase4\Collect-NetworkEvidence.ps1 -EvidenceDirectory <run folder> -ProcessLog <run folder>\processes.csv -CaseTimeline <run folder>\results.json -FailOnFindings
.\tests\phase4\Assert-NetworkBlocked.ps1    # the block must still hold at the end
```

## Harness development on a connected machine

`Invoke-Phase4.ps1 -DryRunOnConnectedHost` expects an open network in P0 and tolerates a dirty host. The run folder is labeled `-dryrun`, and its summary states that it is not a Phase 4 result. Use `-SkipInstall -InstallRoot <existing install>` to iterate without the 14-minute install.
