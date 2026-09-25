<#
.SYNOPSIS
Points an Offline Hermes install at a local or LAN OpenAI-compatible model server
(for example vLLM, llama.cpp server, Ollama or NIM on a GPU box) and checks it.

.DESCRIPTION
Writes the provider settings into the offline Hermes home with the installed
Hermes CLI (hermes config set), so no YAML is hand-edited:

  model.provider       custom
  model.base_url       -BaseUrl
  model.default        -Model
  model.context_length -ContextLength   (optional; otherwise detected from the server)
  model.key_env        -ApiKeyEnv       (optional; for servers that require a key)

The API key itself is never written here. If the server needs one, put
<ApiKeyEnv>=<key> in the home's .env file (<home>\.env) yourself.

Then it calls GET <BaseUrl>/models on the local network (no Internet) and
reports whether the server answers and lists -Model. With a provider
configured, the desktop's first-run provider screen (and its cloud lookups)
no longer appears.

.EXAMPLE
.\scripts\configure-provider.ps1 -BaseUrl http://192.168.1.50:8000/v1 -Model my-model
.\scripts\configure-provider.ps1 -BaseUrl http://gb10.lan:8000/v1 -Model my-model -ContextLength 131072 -ApiKeyEnv GB10_API_KEY
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseUrl,
    [Parameter(Mandatory)][string]$Model,
    [Parameter()][int]$ContextLength = 0,
    [Parameter()][string]$ApiKeyEnv,
    [Parameter()][string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'OfflineHermes'),
    [Parameter()][switch]$SkipCheck,
    [Parameter()][int]$TimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\OfflineHermes.psm1') -Force

function Test-PublicAddress {
    param([System.Net.IPAddress]$Ip)
    if ([System.Net.IPAddress]::IsLoopback($Ip)) { return $false }
    $b = $Ip.GetAddressBytes()
    if ($Ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        if ($b[0] -eq 10 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254)) { return $false }
        if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $false }   # CGNAT / tailnet ranges
        return $true
    }
    if ($Ip.IsIPv6LinkLocal -or (($b[0] -band 0xfe) -eq 0xfc)) { return $false }
    return $true
}

try {
    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl.TrimEnd('/'), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https')) {
        throw "BaseUrl must be an absolute http:// or https:// URL, for example http://192.168.1.50:8000/v1 (got '$BaseUrl')."
    }
    $base = $uri.AbsoluteUri.TrimEnd('/')
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($uri.Host, [ref]$ip) -and (Test-PublicAddress $ip)) {
        Write-Warning "$($uri.Host) is a public Internet address. An offline deployment should point at a loopback or LAN model server."
    }
    # Hermes refuses models with less context than this (agent/model_metadata.py
    # MINIMUM_CONTEXT_LENGTH); catch it here rather than at the first chat.
    $minimumContext = 64000
    if ($ContextLength -gt 0 -and $ContextLength -lt $minimumContext) {
        throw "ContextLength $ContextLength is below the $minimumContext tokens Hermes Agent requires. Serve the model with a larger window (vLLM: --max-model-len 65536 or more; llama.cpp: -c 65536; Ollama: OLLAMA_CONTEXT_LENGTH=65536) and pass that value."
    }
    if ($ApiKeyEnv -and $ApiKeyEnv -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "ApiKeyEnv must be an environment variable NAME (for example GB10_API_KEY), not the key itself."
    }

    $statePath = Join-Path $InstallRoot 'install-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "No Offline Hermes install at $InstallRoot (missing install-state.json). Pass -InstallRoot."
    }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $hermesHome = if ($env:OFFLINE_HERMES_HOME) { $env:OFFLINE_HERMES_HOME } else { $state.hermes_home }
    $hermesExe = Join-Path $InstallRoot 'venv\Scripts\hermes.exe'
    if (-not (Test-Path -LiteralPath $hermesExe -PathType Leaf)) { throw "Hermes CLI not found: $hermesExe" }

    $settings = [ordered]@{
        'model.provider' = 'custom'
        'model.base_url' = $base
        'model.default'  = $Model
    }
    if ($ContextLength -gt 0) { $settings['model.context_length'] = [string]$ContextLength }
    if ($ApiKeyEnv) { $settings['model.key_env'] = $ApiKeyEnv }

    $cliEnv = @{ HERMES_HOME = $hermesHome; HERMES_DISABLE_LAZY_INSTALLS = '1'; UV_OFFLINE = '1'; PIP_NO_INDEX = '1' }
    Invoke-WithEnvironment -Variables $cliEnv -ScriptBlock {
        foreach ($key in $settings.Keys) {
            $output = & $hermesExe config set $key $settings[$key] 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "hermes config set $key failed (exit $LASTEXITCODE):`n$output" }
        }
    }
    Write-Host "Provider saved in $hermesHome\config.yaml:"
    foreach ($key in $settings.Keys) { Write-Host ("  {0,-22} {1}" -f $key, $settings[$key]) }
    if ($ApiKeyEnv) {
        $envFile = Join-Path $hermesHome '.env'
        $hasKey = (Test-Path -LiteralPath $envFile) -and ((Get-Content -LiteralPath $envFile -Raw) -match "(?m)^\s*$([regex]::Escape($ApiKeyEnv))\s*=")
        if (-not $hasKey -and -not [Environment]::GetEnvironmentVariable($ApiKeyEnv)) {
            Write-Warning "Add '$ApiKeyEnv=<your key>' to $envFile. The key is not stored by this script."
        }
    }

    if ($SkipCheck) { return }

    # Local-network check of the endpoint. Nothing here goes to the Internet
    # unless BaseUrl itself points there.
    Write-Host "Checking $base/models ..."
    $headers = @{}
    $key = if ($ApiKeyEnv) { [Environment]::GetEnvironmentVariable($ApiKeyEnv) } else { $null }
    if (-not $key -and $ApiKeyEnv) {
        $envFile = Join-Path $hermesHome '.env'
        if (Test-Path -LiteralPath $envFile) {
            $line = Get-Content -LiteralPath $envFile | Where-Object { $_ -match "^\s*$([regex]::Escape($ApiKeyEnv))\s*=" } | Select-Object -First 1
            if ($line) { $key = ($line -split '=', 2)[1].Trim().Trim('"', "'") }
        }
    }
    if ($key) { $headers['Authorization'] = "Bearer $key" }
    if ($uri.Scheme -eq 'https') { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
    try {
        $response = Invoke-WebRequest -Uri "$base/models" -Headers $headers -UseBasicParsing -TimeoutSec $TimeoutSeconds
    }
    catch {
        throw "The model server did not answer at $base/models: $($_.Exception.Message)`nThe provider is saved; start the server (or fix the address) and rerun with the same arguments to check again."
    }
    $payload = $response.Content | ConvertFrom-Json
    $models = @($payload.data)
    $ids = @($models | ForEach-Object { $_.id })
    Write-Host "Server answered; models: $($ids -join ', ')"
    $match = @($models | Where-Object { $_.id -eq $Model })
    if ($match.Count -eq 0) {
        Write-Warning "'$Model' is not in the server's model list. Chats will fail until -Model matches one of: $($ids -join ', ')"
        exit 2
    }
    $advertised = $null
    foreach ($field in 'max_model_len', 'context_length', 'max_context_length') {
        if ($match[0].PSObject.Properties[$field]) { $advertised = $match[0].$field; break }
    }
    if ($advertised) {
        Write-Host "The server advertises a context window of $advertised tokens for $Model."
        if ([int64]$advertised -lt $minimumContext) {
            Write-Warning "That is below the $minimumContext tokens Hermes Agent requires; chats will be refused. Restart the server with a larger window (vLLM: --max-model-len 65536 or more)."
            exit 2
        }
    } elseif ($ContextLength -le 0) {
        Write-Warning "The server does not advertise a context window for $Model; pass -ContextLength so Hermes sizes history correctly."
    }
    Write-Host "Provider check passed."
}
catch {
    Write-OfflineHermesFailure $_
    exit 1
}
