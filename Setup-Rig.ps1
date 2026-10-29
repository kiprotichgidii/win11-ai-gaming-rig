<#
.SYNOPSIS
    One-time provisioner for Windows 11: WSL2, Hyper-V, Docker, Sunshine, and the AI stack.
.DESCRIPTION
    Run this once on a fresh Windows 11 machine (bare-metal or VM).
    If a reboot is required after enabling system features, re-run the script and it will
    pick up from where it left off. Every phase is fully idempotent.
.EXAMPLE
    # Run locally:
    .\Setup-Rig.ps1

    # Run directly from GitHub (no Git required):
    irm "https://raw.githubusercontent.com/kiprotichgidii/win11-ai-gaming-rig/main/Setup-Rig.ps1?$(Get-Random)" | iex
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

function Write-Step ($msg) { Write-Host "`n[+] $msg" -ForegroundColor Cyan }
function Write-OK   ($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "[!]  $msg" -ForegroundColor Yellow }

# ============================================================
# PHASE 0 — Detect hardware (GPU vs CPU/VM)
# ============================================================
Write-Step "Phase 0: Detecting hardware environment..."

$hasGPU = [bool](Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like "*NVIDIA*" })
$isVM   = (Get-CimInstance Win32_ComputerSystem).Model -match "Virtual|VMware|VirtualBox|KVM|QEMU|Hyper-V"

Write-OK "Mode : $(if ($hasGPU) { 'Bare-metal (NVIDIA GPU detected)' } else { 'Test VM (CPU fallback)' })"
Write-OK "VM   : $isVM"

# ============================================================
# PHASE 1 — Windows optional features
# ============================================================
Write-Step "Phase 1: Enabling required Windows features..."

$features = @("Microsoft-Hyper-V-All", "VirtualMachinePlatform", "Microsoft-Windows-Subsystem-Linux")
$needsReboot = $false

foreach ($f in $features) {
    $state = Get-WindowsOptionalFeature -Online -FeatureName $f
    if ($state.State -ne "Enabled") {
        Write-Warn "Enabling $f..."
        $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -NoRestart
        if ($r.RestartNeeded) { $needsReboot = $true }
    } else {
        Write-OK "$f already enabled."
    }
}

if ($needsReboot) {
    Write-Host "`n[REBOOT REQUIRED] Re-run this script after restarting." -ForegroundColor Red
    $ans = Read-Host "Reboot now? (Y/n)"
    if ($ans -ne 'n') { Restart-Computer }
    return
}

# ============================================================
# PHASE 2 — WSL2 mirrored networking + permanent DNS fix
# ============================================================
Write-Step "Phase 2: Configuring WSL2 networking and DNS..."

$wslConfig = "$env:USERPROFILE\.wslconfig"
if (-not (Test-Path $wslConfig) -or (Get-Content $wslConfig -Raw) -notmatch "networkingMode=mirrored") {
    Set-Content $wslConfig -Encoding UTF8 -Value @"
[wsl2]
networkingMode=mirrored
autoProxy=true
dnsTunneling=true

[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
"@
    Write-OK "WSL2 mirrored networking configured."
} else {
    Write-OK "WSL2 config already set."
}

# Permanently pin public DNS inside WSL2 (survives reboots)
if (Get-Command wsl -ErrorAction SilentlyContinue) {
    wsl -u root -e sh -c "echo '[network]' > /etc/wsl.conf && echo 'generateResolvConf = false' >> /etc/wsl.conf" 2>$null
    wsl -u root -e sh -c "printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf" 2>$null
    wsl --shutdown 2>$null
    Write-OK "WSL2 DNS permanently set to 8.8.8.8 / 1.1.1.1."
}

# Inject public DNS into Docker daemon.json
$daemonDir  = "$env:USERPROFILE\.docker"
$daemonJson = "$daemonDir\daemon.json"
if (-not (Test-Path $daemonDir)) { New-Item -ItemType Directory $daemonDir -Force | Out-Null }
'{"dns":["8.8.8.8","1.1.1.1"]}' | Set-Content $daemonJson -Encoding UTF8
Write-OK "Docker daemon DNS set to 8.8.8.8 / 1.1.1.1."

# ============================================================
# PHASE 3 — Hyper-V external bridged switch
# ============================================================
Write-Step "Phase 3: Configuring Hyper-V external switch..."

$switchName = "Bridged-External-Switch"
if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
    $adapter = Get-NetAdapter | Where-Object {
        $_.Status -eq "Up" -and $_.InterfaceDescription -notmatch "Hyper-V|vEthernet|Loopback|WSL"
    } | Select-Object -First 1

    if ($adapter) {
        New-VMSwitch -Name $switchName -NetAdapterName $adapter.Name -AllowManagementOS $true | Out-Null
        Write-OK "Switch '$switchName' created on '$($adapter.Name)'."
    } else {
        Write-Warn "No physical adapter found — create the Hyper-V switch manually."
    }
} else {
    Write-OK "Switch '$switchName' already exists."
}

# ============================================================
# PHASE 4 — Firewall rules
# ============================================================
Write-Step "Phase 4: Configuring firewall rules..."

$rules = @(
    @{ Name = "AI-Ollama";         Port = 11434; Proto = "TCP" },
    @{ Name = "AI-OpenWebUI";      Port = 3000;  Proto = "TCP" },
    @{ Name = "AI-ComfyUI";        Port = 8188;  Proto = "TCP" },
    @{ Name = "Sunshine-HTTP";     Port = 47984; Proto = "TCP" },
    @{ Name = "Sunshine-HTTPS";    Port = 47990; Proto = "TCP" },
    @{ Name = "Sunshine-Video";    Port = 47998; Proto = "UDP" },
    @{ Name = "Sunshine-Control";  Port = 47999; Proto = "UDP" },
    @{ Name = "Sunshine-Audio";    Port = 48000; Proto = "UDP" },
    @{ Name = "Sunshine-QoS";      Port = 48010; Proto = "UDP" }
)

foreach ($r in $rules) {
    if (-not (Get-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $r.Name -DisplayName $r.Name `
            -Direction Inbound -Action Allow -Protocol $r.Proto `
            -LocalPort $r.Port -Profile Any | Out-Null
        Write-OK "Rule '$($r.Name)' ($($r.Proto) $($r.Port)) created."
    } else {
        Write-OK "Rule '$($r.Name)' already exists."
    }
}

# ============================================================
# PHASE 5 — Software installation (Docker, Sunshine, ViGEmBus)
# ============================================================
Write-Step "Phase 5: Installing required software..."

# Helper: install via winget with direct-download fallback
function Install-Package {
    param($Id, $Name, $TestPath, $FallbackUrl, $FallbackArgs)
    if ((Get-Command $Name -ErrorAction SilentlyContinue) -or (Test-Path $TestPath)) {
        Write-OK "$Name already installed."
        return
    }
    Write-Warn "Installing $Name via winget..."
    $proc = Start-Process winget -ArgumentList "install --id $Id --source winget -e --accept-package-agreements --accept-source-agreements --silent" -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0 -and $FallbackUrl) {
        Write-Warn "Winget failed. Downloading $Name directly..."
        $tmp = "$env:TEMP\$Name-installer.exe"
        $prev = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest $FallbackUrl -OutFile $tmp -UseBasicParsing
        $ProgressPreference = $prev
        Start-Process $tmp -ArgumentList $FallbackArgs -Wait
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    Write-OK "$Name installation complete."
}

Install-Package `
    -Id "Docker.DockerDesktop" -Name "docker" `
    -TestPath "C:\Program Files\Docker\Docker\Docker Desktop.exe" `
    -FallbackUrl "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" `
    -FallbackArgs "install --quiet --accept-license --backend=wsl-2"

Install-Package `
    -Id "Nefarius.ViGEmBus" -Name "ViGEmBus" `
    -TestPath "C:\Program Files\Nefarius Software Solutions\ViGEm Bus Driver\ViGEmBusDriver.exe"

Install-Package `
    -Id "LizardByte.Sunshine" -Name "Sunshine" `
    -TestPath "C:\Program Files\Sunshine\sunshine.exe"

# Refresh PATH so docker is available in this session
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")
$dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
if ((Test-Path $dockerBin) -and ($env:Path -notlike "*$dockerBin*")) {
    $env:Path = "$dockerBin;$env:Path"
}

# ============================================================
# PHASE 6 — Deploy AI stack
# ============================================================
Write-Step "Phase 6: Deploying AI stack to C:\ai-stack..."

$stackDir = "C:\ai-stack"
if (-not (Test-Path $stackDir)) { New-Item -ItemType Directory $stackDir -Force | Out-Null }

# Pick the correct compose file based on hardware; write it as compose.yaml
$sourceFile = if ($hasGPU) { "compose.gpu.yaml" } else { "compose.cpu.yaml" }

# If running via iex, the source files won't exist locally — download from GitHub
$composeDest = "$stackDir\compose.yaml"
$rawBase = "https://raw.githubusercontent.com/kiprotichgidii/win11-ai-gaming-rig/main"

if (-not (Test-Path "$PSScriptRoot\$sourceFile")) {
    Write-Warn "Downloading $sourceFile from GitHub..."
    $prev = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest "$rawBase/$sourceFile" -OutFile $composeDest -UseBasicParsing
    $ProgressPreference = $prev
} else {
    Copy-Item "$PSScriptRoot\$sourceFile" $composeDest -Force
}
Write-OK "compose.yaml written ($sourceFile → $composeDest)."

# Start Docker Desktop if not already running
$dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if ((Test-Path $dockerExe) -and (-not (Get-Process "Docker Desktop" -ErrorAction SilentlyContinue))) {
    Write-Warn "Starting Docker Desktop..."
    Start-Process $dockerExe
    Write-Warn "Waiting for Docker daemon (up to 60s)..."
    for ($i = 0; $i -lt 30; $i++) {
        docker info >$null 2>&1; if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep 2
    }
}

# Verify images (pulls ONLY if missing locally)
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

# Launch stack
Set-Location $stackDir
Write-Step "Starting AI stack containers..."
docker compose up -d

Write-Step "Ensuring required chat & embedding models are loaded in Ollama..."
$models = @("llama3.1:8b", "qwen2.5-coder:7b", "nomic-embed-text")
foreach ($m in $models) {
    Write-Host "Checking / loading $m..." -ForegroundColor Cyan
    docker exec ollama ollama pull $m
}

# ============================================================
# SUMMARY
# ============================================================
$hostIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.InterfaceAlias -notmatch "vEthernet|Loopback|WSL" -and $_.IPAddress -notlike "169.254*"
} | Select-Object -First 1).IPAddress

Write-Host "`n$(('=' * 60))" -ForegroundColor Green
Write-Host " All done!" -ForegroundColor Green
Write-Host "$(('=' * 60))" -ForegroundColor Green
Write-Host " Mode        : $(if ($hasGPU) { 'GPU (NVIDIA)' } else { 'CPU (Test VM)' })"
Write-Host " Host IP     : $hostIP"
Write-Host " Ollama API  : http://${hostIP}:11434"
Write-Host " Open WebUI  : http://${hostIP}:3000"
Write-Host " ComfyUI     : http://${hostIP}:8188"
Write-Host " Sunshine    : https://${hostIP}:47990"
Write-Host " Hyper-V NIC : $switchName"
Write-Host "$(('=' * 60))" -ForegroundColor Green
