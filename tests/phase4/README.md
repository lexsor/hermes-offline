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
| `desktop-checklist.md` | — | Manual cases T7–T10 and T12. |
| `static-checks.sh` | — | File presence, the no-public-URL rule, the safety interlocks, and PowerShell parse checks. |

## Run order on the VM

```powershell
# elevated, once, from the S1-staged snapshot
.\tests\phase4\Enable-NetworkBlock.ps1 -IUnderstandThisBlocksAllOutboundTraffic -AlsoRemoveRoutesAndDns

# standard user
.\tests\phase4\Invoke-Phase4.ps1 -Cases P0,T1,T2,T3,T4,T5,T6,T11
# then the manual cases in desktop-checklist.md

# elevated
.\tests\phase4\Collect-NetworkEvidence.ps1 -EvidenceDirectory <run folder> -ProcessLog <run folder>\processes.csv -CaseTimeline <run folder>\results.json -FailOnFindings
.\tests\phase4\Assert-NetworkBlocked.ps1    # the block must still hold at the end
```

## Harness development on a connected machine

`Invoke-Phase4.ps1 -DryRunOnConnectedHost` expects an open network in P0 and tolerates a dirty host. The run folder is labeled `-dryrun`, and its summary states that it is not a Phase 4 result. Use `-SkipInstall -InstallRoot <existing install>` to iterate without the 14-minute install.
