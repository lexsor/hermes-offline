<#
.SYNOPSIS
Builds and manages the Hyper-V test VM for Phase 4 network-blocked validation.

.DESCRIPTION
Run on the Hyper-V HOST, in stages (see docs/phase-4-validation-plan.md section 1):

  Create           Elevated. New Generation 2 Windows 11 VM (TPM, Secure Boot) booting from
                   your ISO, attached to 'Default Switch' so Windows can install and patch.
                   Then install Windows in the VM console with a local administrator
                   account, apply updates, and run Isolate.
  Isolate          Elevated. Over PowerShell Direct: enable long paths, run the clean-host
                   preflight, move the NIC to a Private switch (no host or Internet path),
                   eject the ISO, and checkpoint 'S0-clean'.
  Export           Not elevated; no Hyper-V needed. Exports this repository's working tree
                   without .git, verifies every vendored checksum on the export (which
                   catches Git LFS pointer files), and tars it with a SHA-256 manifest.
  Stage            Elevated. Export (unless -ExportTar is given), copy the tar into the VM
                   over PowerShell Direct (VMBus, no network), verify its hash in the guest,
                   extract to C:\OfflineHermes-src, run verify-deps in the guest, enable the
                   in-guest firewall block, and checkpoint 'S1-staged'.
  Reset            Elevated. Restore 'S1-staged' for a fresh test run.
  CollectEvidence  Elevated. Copy the guest's phase4-evidence folder to the host.

Nothing is downloaded. The Windows ISO is supplied by you.

.EXAMPLE
.\tests\phase4\New-Phase4Vm.ps1 -Stage Create -IsoPath D:\iso\Win11_Enterprise_Eval.iso
.\tests\phase4\New-Phase4Vm.ps1 -Stage Isolate
.\tests\phase4\New-Phase4Vm.ps1 -Stage Stage
.\tests\phase4\New-Phase4Vm.ps1 -Stage CollectEvidence -HostEvidenceDirectory D:\phase4-runs
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Create', 'Isolate', 'Export', 'Stage', 'Reset', 'CollectEvidence')][string]$Stage,
    [Parameter()][string]$VmName = 'OfflineHermes-Phase4',
    [Parameter()][string]$VmRoot = (Join-Path $env:PUBLIC 'Documents\Hyper-V\OfflineHermes-Phase4'),
    [Parameter()][string]$IsoPath,
    [Parameter()][int]$ProcessorCount = 4,
    [Parameter()][long]$MemoryBytes = 16GB,
    [Parameter()][long]$DiskBytes = 120GB,
    [Parameter()][string]$SetupSwitchName = 'Default Switch',
    [Parameter()][string]$IsolatedSwitchName = 'OfflineHermes-Isolated',
    # Guest local administrator; prompted for when a stage needs PowerShell Direct.
    [Parameter()][pscredential]$Credential,
    # Export output directory (default: a temp folder).
    [Parameter()][string]$ExportDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'OfflineHermes-phase4-export'),
    # Stage an existing export instead of creating a new one.
    [Parameter()][string]$ExportTar,
    # Allow exporting a working tree with uncommitted changes (recorded in the manifest).
    [Parameter()][switch]$AllowDirtyTree,
    [Parameter()][string]$GuestSourceRoot = 'C:\OfflineHermes-src',
    [Parameter()][string]$HostEvidenceDirectory = (Join-Path (Get-Location) 'phase4-evidence-from-vm')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Phase4.psm1') -Force

$repoRoot = Get-Phase4RepoRoot

function Assert-HyperVHost {
    if (-not (Test-IsAdministrator)) {
        throw "Stage '$Stage' must run from an elevated PowerShell on the Hyper-V host."
    }
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw @'
The Hyper-V PowerShell module is not available on this host.
Enable Hyper-V (Windows 10/11 Pro, Enterprise or Education) from an elevated PowerShell, then reboot:

  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All

This script does not change Windows features itself.
'@
    }
}

function Get-Phase4Vm {
    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm) { throw "VM '$VmName' does not exist. Run -Stage Create first." }
    return $vm
}

function Get-GuestCredential {
    if ($script:Credential) { return $script:Credential }
    $script:Credential = Get-Credential -Message "Local administrator account inside VM '$VmName'"
    return $script:Credential
}

function New-GuestSession {
    $vm = Get-Phase4Vm
    if ($vm.State -ne 'Running') { throw "VM '$VmName' is $($vm.State); start it and sign in once before this stage." }
    $credential = Get-GuestCredential
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while ($true) {
        try {
            return New-PSSession -VMName $VmName -Credential $credential -ErrorAction Stop
        }
        catch {
            if ([DateTime]::UtcNow -gt $deadline) {
                throw "PowerShell Direct to '$VmName' failed: $($_.Exception.Message)`nCheck the credential, and that the guest has finished booting."
            }
            Start-Sleep -Seconds 5
        }
    }
}

function New-RepositoryExport {
    # Returns the tar path. The export is what the VM tests: a working tree
    # without .git, with real LFS content, verified before it leaves the host.
    $commit = $null
    $dirty = @()
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $commit = (& git -C $repoRoot rev-parse HEAD 2>$null)
        $dirty = @(& git -C $repoRoot status --porcelain 2>$null)
    }
    if ($dirty.Count -gt 0 -and -not $AllowDirtyTree) {
        throw "The working tree has $($dirty.Count) uncommitted change(s). Commit them, or pass -AllowDirtyTree (recorded in the export manifest)."
    }

    $tree = Join-Path $ExportDirectory 'OfflineHermes-src'
    if (Test-Path -LiteralPath $ExportDirectory) { Remove-Item -LiteralPath $ExportDirectory -Recurse -Force }
    New-Item -ItemType Directory -Path $tree -Force | Out-Null

    Write-Host "Exporting $repoRoot (without .git and local run output)..."
    & robocopy.exe $repoRoot $tree /E /XD (Join-Path $repoRoot '.git') (Join-Path $repoRoot 'phase4-evidence') `
        (Join-Path $repoRoot 'phase4-evidence-from-vm') (Join-Path $repoRoot 'dist') (Join-Path $repoRoot 'reports\evidence') `
        /XF '.env' /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy export failed with exit code $LASTEXITCODE." }

    Write-Host 'Verifying vendored checksums on the export (detects Git LFS pointer files)...'
    # verify-deps.ps1 only calls exit on failure; clear robocopy's code (1 =
    # files copied) so a successful verification is not misread.
    $global:LASTEXITCODE = 0
    & (Join-Path $tree 'scripts\verify-deps.ps1') -RepoRoot $tree
    if ($LASTEXITCODE -ne 0) {
        throw "Checksum verification failed on the export. If files are Git LFS pointers, run 'git lfs pull' in $repoRoot first."
    }

    $tar = Join-Path $ExportDirectory 'OfflineHermes-src.tar'
    Write-Host "Creating $tar..."
    & tar.exe -cf $tar -C $ExportDirectory 'OfflineHermes-src'
    if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE." }
    Remove-Item -LiteralPath $tree -Recurse -Force

    $manifest = [ordered]@{
        created_utc = [DateTime]::UtcNow.ToString('o')
        source_repository = $repoRoot
        commit = $commit
        uncommitted_changes = $dirty
        tar = (Split-Path $tar -Leaf)
        tar_bytes = (Get-Item -LiteralPath $tar).Length
        tar_sha256 = (Get-FileHash -LiteralPath $tar -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    Write-EvidenceJson -Path "$tar.manifest.json" -InputObject $manifest
    Write-Host "Export ready: $tar ($([Math]::Round($manifest.tar_bytes / 1MB)) MB, sha256 $($manifest.tar_sha256))"
    return $tar
}

switch ($Stage) {
    'Create' {
        Assert-HyperVHost
        if (-not $IsoPath -or -not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
            throw 'Pass -IsoPath <Windows 10/11 x64 ISO>. The script never downloads an ISO; use a Windows evaluation or licensed image you obtained yourself.'
        }
        if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) { throw "VM '$VmName' already exists." }
        if (-not (Get-VMSwitch -Name $SetupSwitchName -ErrorAction SilentlyContinue)) {
            throw "Setup switch '$SetupSwitchName' not found. Pass -SetupSwitchName with an external or NAT switch for Windows setup."
        }
        if (-not (Get-VMSwitch -Name $IsolatedSwitchName -ErrorAction SilentlyContinue)) {
            New-VMSwitch -Name $IsolatedSwitchName -SwitchType Private | Out-Null
            Write-Host "Created private switch '$IsolatedSwitchName' (no host or external connectivity)."
        }

        New-Item -ItemType Directory -Path $VmRoot -Force | Out-Null
        $vhd = Join-Path $VmRoot "$VmName.vhdx"
        New-VM -Name $VmName -Generation 2 -Path $VmRoot -MemoryStartupBytes $MemoryBytes `
            -NewVHDPath $vhd -NewVHDSizeBytes $DiskBytes -SwitchName $SetupSwitchName | Out-Null
        Set-VMMemory -VMName $VmName -DynamicMemoryEnabled $false
        Set-VMProcessor -VMName $VmName -Count $ProcessorCount
        # Windows 11 requires TPM 2.0 and Secure Boot.
        Set-VMKeyProtector -VMName $VmName -NewLocalKeyProtector
        Enable-VMTPM -VMName $VmName
        Set-VMFirmware -VMName $VmName -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'
        # Standard checkpoints capture memory, so S1-staged restores to a
        # signed-in, network-blocked session. No surprise automatic checkpoints.
        Set-VM -VMName $VmName -CheckpointType Standard -AutomaticCheckpointsEnabled $false
        $dvd = Add-VMDvdDrive -VMName $VmName -Path $IsoPath -Passthru
        Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd
        Start-VM -Name $VmName

        Write-Host @"

VM '$VmName' created and started from $IsoPath.
Next, in the VM console (vmconnect localhost "$VmName"):
  1. Press a key to boot from the DVD and install Windows. Create a LOCAL administrator account.
  2. Install all Windows updates and reboot until none remain.
  3. Do NOT install Python, Node, Git, or anything else.
Then run: .\tests\phase4\New-Phase4Vm.ps1 -Stage Isolate
"@
    }

    'Isolate' {
        Assert-HyperVHost
        $vm = Get-Phase4Vm
        if (Get-VMCheckpoint -VMName $VmName -Name 'S0-clean' -ErrorAction SilentlyContinue) {
            throw "Checkpoint 'S0-clean' already exists."
        }
        $session = New-GuestSession
        try {
            Invoke-Command -Session $session -ScriptBlock {
                Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -Type DWord
            }
            # Run the same P0 clean-host check the harness uses, from a temp copy.
            $guestModule = 'C:\Windows\Temp\Phase4.psm1'
            Copy-Item -ToSession $session -Path (Join-Path $PSScriptRoot 'Phase4.psm1') -Destination $guestModule -Force
            $findings = @(Invoke-Command -Session $session -ArgumentList $guestModule -ScriptBlock {
                param($module)
                Import-Module $module -Force
                Get-CleanHostFindings
                Remove-Item $module -Force
            })
            if ($findings.Count -gt 0) {
                $findings | ForEach-Object { Write-Warning "guest: $_" }
                throw 'The guest is not clean (see warnings). Fix it, or rebuild from the ISO, before isolating.'
            }
            Write-Host 'Guest clean-host preflight passed; long paths enabled.'
        }
        finally {
            Remove-PSSession $session
        }

        Connect-VMNetworkAdapter -VMName $VmName -SwitchName $IsolatedSwitchName
        Get-VMDvdDrive -VMName $VmName | Set-VMDvdDrive -Path $null
        Checkpoint-VM -Name $VmName -SnapshotName 'S0-clean'
        Write-Host "NIC moved to private switch '$IsolatedSwitchName'; ISO ejected; checkpoint 'S0-clean' taken."
        Write-Host 'Next: .\tests\phase4\New-Phase4Vm.ps1 -Stage Stage'
    }

    'Export' {
        New-RepositoryExport | Out-Null
    }

    'Stage' {
        Assert-HyperVHost
        $vm = Get-Phase4Vm
        $adapter = Get-VMNetworkAdapter -VMName $VmName
        if (@($adapter | Where-Object { $_.SwitchName -and $_.SwitchName -ne $IsolatedSwitchName }).Count -gt 0) {
            throw "VM '$VmName' has a network adapter on a non-isolated switch. Run -Stage Isolate first."
        }
        if (Get-VMCheckpoint -VMName $VmName -Name 'S1-staged' -ErrorAction SilentlyContinue) {
            throw "Checkpoint 'S1-staged' already exists. Remove it, or use -Stage Reset."
        }

        $tar = if ($ExportTar) { (Resolve-Path -LiteralPath $ExportTar).Path } else { New-RepositoryExport }
        $manifestPath = "$tar.manifest.json"
        if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Export manifest not found: $manifestPath" }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

        $session = New-GuestSession
        try {
            $guestTar = "C:\OfflineHermes-src.tar"
            Write-Host "Copying $([Math]::Round($manifest.tar_bytes / 1MB)) MB into the VM over PowerShell Direct..."
            Copy-Item -ToSession $session -Path $tar -Destination $guestTar -Force
            Copy-Item -ToSession $session -Path $manifestPath -Destination "$guestTar.manifest.json" -Force

            Invoke-Command -Session $session -ArgumentList $guestTar, $manifest.tar_sha256, $GuestSourceRoot -ScriptBlock {
                param($guestTar, $expectedHash, $sourceRoot)
                $ErrorActionPreference = 'Stop'
                $actual = (Get-FileHash -LiteralPath $guestTar -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actual -ne $expectedHash) { throw "Tar hash mismatch in guest: expected $expectedHash, got $actual" }
                if (Test-Path -LiteralPath $sourceRoot) { throw "$sourceRoot already exists in the guest." }
                & tar.exe -xf $guestTar -C (Split-Path $sourceRoot -Parent)
                if ($LASTEXITCODE -ne 0) { throw "tar extraction failed in guest ($LASTEXITCODE)." }
                Move-Item -LiteralPath $guestTar -Destination (Join-Path $sourceRoot '..\OfflineHermes-src.tar.staged') -Force
                Write-Host "Guest: tar hash verified and extracted to $sourceRoot"
            }

            # PowerShell Direct runs Windows PowerShell 5.1 in the guest, the
            # same engine a clean target has; every script must work under it.
            Invoke-Command -Session $session -ArgumentList $GuestSourceRoot -ScriptBlock {
                param($sourceRoot)
                $ErrorActionPreference = 'Stop'
                Set-Location $sourceRoot
                $global:LASTEXITCODE = 0
                & (Join-Path $sourceRoot 'scripts\verify-deps.ps1')
                if ($LASTEXITCODE -ne 0) { throw "verify-deps.ps1 failed in the guest ($LASTEXITCODE)." }
                $global:LASTEXITCODE = 0
                & (Join-Path $sourceRoot 'tests\phase4\Enable-NetworkBlock.ps1') -IUnderstandThisBlocksAllOutboundTraffic -AlsoRemoveRoutesAndDns
                if ($LASTEXITCODE -ne 0) { throw "Enable-NetworkBlock.ps1 failed in the guest ($LASTEXITCODE)." }
            }
        }
        finally {
            Remove-PSSession $session
        }

        Checkpoint-VM -Name $VmName -SnapshotName 'S1-staged'
        Write-Host @"

Staged commit $($manifest.commit) (tar sha256 $($manifest.tar_sha256)) at $GuestSourceRoot.
Network blocked in the guest; checkpoint 'S1-staged' taken.
Next, in the VM console as a standard user, follow tests\phase4\README.md (Invoke-Phase4.ps1, desktop-checklist.md).
Restore with: .\tests\phase4\New-Phase4Vm.ps1 -Stage Reset
"@
    }

    'Reset' {
        Assert-HyperVHost
        $checkpoint = Get-VMCheckpoint -VMName $VmName -Name 'S1-staged' -ErrorAction SilentlyContinue
        if (-not $checkpoint) { throw "Checkpoint 'S1-staged' not found. Run -Stage Stage first." }
        Restore-VMCheckpoint -VMSnapshot $checkpoint -Confirm:$false
        if ((Get-VM -Name $VmName).State -ne 'Running') { Start-VM -Name $VmName }
        Write-Host "Restored '$VmName' to 'S1-staged'."
    }

    'CollectEvidence' {
        Assert-HyperVHost
        $session = New-GuestSession
        try {
            $guestEvidence = Invoke-Command -Session $session -ArgumentList $GuestSourceRoot -ScriptBlock {
                param($sourceRoot)
                $candidates = @((Join-Path $sourceRoot 'phase4-evidence'), (Join-Path $sourceRoot 'reports\evidence'))
                @($candidates | Where-Object { Test-Path -LiteralPath $_ })
            }
            if (@($guestEvidence).Count -eq 0) { throw "No evidence folders found under $GuestSourceRoot in the guest." }
            $destination = Join-Path $HostEvidenceDirectory ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            foreach ($folder in @($guestEvidence)) {
                Copy-Item -FromSession $session -Path $folder -Destination $destination -Recurse -Force
            }
            Write-Host "Copied guest evidence to $destination"
        }
        finally {
            Remove-PSSession $session
        }
    }
}
