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

function Test-FileLocked([string]$Path) {
    if (!(Test-Path $Path)) {
        return $false
    }
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $stream.Close()
        return $false
    } catch {
        return $true
    }
}

function Get-OutputPath([string]$PreferredPath) {
    if (!(Test-FileLocked $PreferredPath)) {
        return $PreferredPath
    }
    $directory = Split-Path -Parent $PreferredPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($PreferredPath)
    $extension = [System.IO.Path]::GetExtension($PreferredPath)
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $fallback = Join-Path $directory "$name`_$timestamp$extension"
    Write-Warning "$PreferredPath is locked. Building $fallback instead."
    return $fallback
}

$envValues = Read-DotEnv ".env"
$devToken = if ($envValues.ContainsKey("AGENT_ENROLLMENT_TOKEN") -and ![string]::IsNullOrWhiteSpace($envValues["AGENT_ENROLLMENT_TOKEN"])) {
    [string]$envValues["AGENT_ENROLLMENT_TOKEN"]
} else {
    "dev-agent-token"
}
$devOutput = Get-OutputPath "build/client_debug_agent_dev.exe"
$configuredOutput = Get-OutputPath "build/client_debug_agent_configured.exe"

$devArgs = @(
    "compile", "exe", "bin/client.dart",
    "-o", $devOutput,
    "-DDEFAULT_RELAY_SERVER_URL=http://127.0.0.1:9998",
    "-DDEFAULT_AGENT_ENROLLMENT_TOKEN=$devToken",
    "-DDEFAULT_AGENT_VERSION=dev"
)
Invoke-Dart $devArgs

$configuredArgs = @(
    "compile", "exe", "bin/client.dart",
    "-o", $configuredOutput,
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
Write-Host "  $devOutput"
Write-Host "  $configuredOutput"
