<#
.SYNOPSIS
    Starts (or restarts) the AI stack. Safe to run at any time.
.DESCRIPTION
    - Refreshes PATH so docker is accessible in the current session.
    - Starts Docker Desktop if it is not already running.
    - Writes a clean compose.yaml to C:\ai-stack (auto-detects GPU vs CPU).
    - Pulls any missing images, then brings the stack up.
.EXAMPLE
    # Run locally:
    .\Start-Stack.ps1

    # Run from GitHub (bypasses CDN cache):
    irm "https://raw.githubusercontent.com/kiprotichgidii/win11-ai-gaming-rig/main/Start-Stack.ps1?$(Get-Random)" | iex
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = "Continue"

function Write-Step ($msg) { Write-Host "`n[+] $msg" -ForegroundColor Cyan }
function Write-OK   ($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "[!]  $msg" -ForegroundColor Yellow }

$stackDir  = "C:\ai-stack"
$dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
$dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
$rawBase   = "https://raw.githubusercontent.com/kiprotichgidii/win11-ai-gaming-rig/main"

# ── 1. Refresh PATH ──────────────────────────────────────────
Write-Step "Refreshing PATH..."
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")
if ((Test-Path $dockerBin) -and ($env:Path -notlike "*$dockerBin*")) {
    $env:Path = "$dockerBin;$env:Path"
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $dockerExe)) {
        Write-Host "[ERR] Docker Desktop not found. Run Setup-Rig.ps1 first." -ForegroundColor Red
        return
    }
}
Write-OK "docker is on PATH."

# ── 2. Ensure Docker Desktop is running ──────────────────────
Write-Step "Checking Docker Desktop..."
if (-not (Get-Process "Docker Desktop" -ErrorAction SilentlyContinue)) {
    Write-Warn "Starting Docker Desktop..."
    Start-Process $dockerExe
    Write-Warn "Waiting for daemon (up to 60s)..."
    for ($i = 0; $i -lt 30; $i++) {
        docker info >$null 2>&1; if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep 2
    }
}

$osType = docker info --format "{{.OSType}}" 2>$null
if ($osType -and $osType -ne "linux") {
    Write-Warn "Docker is in '$osType' mode. Switching to Linux containers..."
    & "C:\Program Files\Docker\Docker\DockerCli.exe" -SwitchLinuxEngine 2>$null
    Start-Sleep 10
}
Write-OK "Docker daemon is running (Linux containers)."

# ── 3. Write clean compose.yaml ──────────────────────────────
Write-Step "Preparing compose.yaml..."
if (-not (Test-Path $stackDir)) { New-Item -ItemType Directory $stackDir -Force | Out-Null }

$hasGPU  = [bool](Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like "*NVIDIA*" })
$srcFile = if ($hasGPU) { "compose.gpu.yaml" } else { "compose.cpu.yaml" }
$dest    = "$stackDir\compose.yaml"
$prev    = $ProgressPreference; $ProgressPreference = "SilentlyContinue"

if (Test-Path "$PSScriptRoot\$srcFile") {
    Copy-Item "$PSScriptRoot\$srcFile" $dest -Force
} else {
    Invoke-WebRequest "$rawBase/$srcFile" -OutFile $dest -UseBasicParsing
}
$ProgressPreference = $prev
Write-OK "compose.yaml written ($srcFile → $dest, $(if ($hasGPU) {'GPU mode'} else {'CPU mode'}))."

# ── 4. Verify images (pulls ONLY if missing locally) ─────────
Write-Step "Verifying container images..."
$requiredImages = @(
    "ollama/ollama:latest",
    "ghcr.io/open-webui/open-webui:main",
    "yanwk/comfyui-boot:cu130-slim-v2"
)

foreach ($img in $requiredImages) {
    docker image inspect $img >$null 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-OK "Image '$img' exists locally. Skipping pull."
    } else {
        Write-Warn "Image '$img' not found. Pulling from registry..."
        docker pull $img
    }
}

Write-Step "Starting stack containers..."
Set-Location $stackDir
docker compose up -d

Write-Host ""
docker compose ps

# ── 5. Summary ───────────────────────────────────────────────
$hostIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.InterfaceAlias -notmatch "vEthernet|Loopback|WSL" -and $_.IPAddress -notlike "169.254*"
} | Select-Object -First 1).IPAddress

Write-Host "`n$(('=' * 55))" -ForegroundColor Green
Write-Host " Stack is live!" -ForegroundColor Green
Write-Host "  Open WebUI : http://${hostIP}:3000"
Write-Host "  ComfyUI    : http://${hostIP}:8188"
Write-Host "  Ollama API : http://${hostIP}:11434"
Write-Host "$(('=' * 55))" -ForegroundColor Green
