$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$BuildDir = Join-Path $RepoRoot "build\c_client"
$OutputDir = Join-Path $RepoRoot "build"
$EnvPath = Join-Path $RepoRoot ".env"

function Read-DotEnv([string]$Path) {
    $values = @{}
    if (!(Test-Path -LiteralPath $Path)) {
        return $values
    }
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
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

function Get-Value($Map, [string]$Key, [string]$Default = "") {
    if ($Map.ContainsKey($Key) -and ![string]::IsNullOrWhiteSpace([string]$Map[$Key])) {
        return [string]$Map[$Key]
    }
    return $Default
}

function Require-Tool([string]$Name) {
    if (!(Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name was not found in PATH. Install CMake and a Windows C++ compiler, or run from a Visual Studio Developer Command Prompt."
    }
}

function Invoke-Step([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

Require-Tool "cmake"

$envValues = Read-DotEnv $EnvPath
$configuredUrl = Get-Value $envValues "RELAY_SERVER_URL"
$configuredToken = Get-Value $envValues "AGENT_ENROLLMENT_TOKEN"
$configuredVersion = Get-Value $envValues "AGENT_VERSION" "1.0.0"
$configuredChromePath = Get-Value $envValues "CHROME_PATH"
$devToken = Get-Value $envValues "AGENT_ENROLLMENT_TOKEN" "dev-agent-token"

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$configureArgs = @(
    "-S", $ScriptDir,
    "-B", $BuildDir,
    "-DCHROME_AGENT_OUTPUT_DIR=$OutputDir",
    "-DDEFAULT_DEV_RELAY_SERVER_URL=http://127.0.0.1:9998",
    "-DDEFAULT_DEV_AGENT_ENROLLMENT_TOKEN=$devToken",
    "-DDEFAULT_DEV_AGENT_VERSION=dev",
    "-DDEFAULT_RELAY_SERVER_URL=$configuredUrl",
    "-DDEFAULT_AGENT_ENROLLMENT_TOKEN=$configuredToken",
    "-DDEFAULT_AGENT_VERSION=$configuredVersion",
    "-DDEFAULT_CHROME_PATH=$configuredChromePath"
)

Invoke-Step "cmake" $configureArgs
Invoke-Step "cmake" @("--build", $BuildDir, "--config", "Release")

Write-Host ""
Write-Host "Built C++ clients:"
Write-Host "  $(Join-Path $OutputDir 'client_debug_agent_cpp_dev.exe')"
Write-Host "  $(Join-Path $OutputDir 'client_debug_agent_cpp.exe')"
