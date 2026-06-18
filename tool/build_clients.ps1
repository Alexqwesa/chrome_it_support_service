$ErrorActionPreference = "Stop"

Set-Location (Split-Path -Parent $PSScriptRoot)
New-Item -ItemType Directory -Force build | Out-Null

function Read-DotEnv([string]$Path) {
    $values = @{}
    if (!(Test-Path $Path)) {
        return $values
    }
    foreach ($rawLine in Get-Content $Path) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith("#")) {
            continue
        }
        if ($line.StartsWith("export ")) {
            $line = $line.Substring(7).TrimStart()
        }
        $separator = $line.IndexOf("=")
        if ($separator -le 0) {
            continue
        }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($value.Length -ge 2) {
            $first = $value[0]
            $last = $value[$value.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $values[$key] = $value
    }
    return $values
}

function Require-Value($Map, [string]$Key) {
    if (!$Map.ContainsKey($Key) -or [string]::IsNullOrWhiteSpace($Map[$Key])) {
        throw "$Key is required in .env to build the configured client."
    }
    return [string]$Map[$Key]
}

function Invoke-Dart($Arguments) {
    & dart @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dart $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

$envValues = Read-DotEnv ".env"

$devArgs = @(
    "compile", "exe", "bin/client.dart",
    "-o", "build/client_debug_agent_dev.exe",
    "-DDEFAULT_RELAY_SERVER_URL=http://127.0.0.1:8080",
    "-DDEFAULT_AGENT_ENROLLMENT_TOKEN=dev-agent-token",
    "-DDEFAULT_AGENT_VERSION=dev"
)
Invoke-Dart $devArgs

$configuredArgs = @(
    "compile", "exe", "bin/client.dart",
    "-o", "build/client_debug_agent_configured.exe",
    "-DDEFAULT_RELAY_SERVER_URL=$(Require-Value $envValues "RELAY_SERVER_URL")",
    "-DDEFAULT_AGENT_ENROLLMENT_TOKEN=$(Require-Value $envValues "AGENT_ENROLLMENT_TOKEN")",
    "-DDEFAULT_AGENT_VERSION=$(if ($envValues.ContainsKey("AGENT_VERSION") -and ![string]::IsNullOrWhiteSpace($envValues["AGENT_VERSION"])) { $envValues["AGENT_VERSION"] } else { "1.0.0" })"
)
if ($envValues.ContainsKey("CHROME_PATH") -and ![string]::IsNullOrWhiteSpace($envValues["CHROME_PATH"])) {
    $configuredArgs += "-DDEFAULT_CHROME_PATH=$($envValues["CHROME_PATH"])"
}
Invoke-Dart $configuredArgs

Write-Host ""
Write-Host "Built:"
Write-Host "  build/client_debug_agent_dev.exe"
Write-Host "  build/client_debug_agent_configured.exe"
