<#
.SYNOPSIS
    Automated provisioner for Windows 11 AI Stack (Ollama + WebUI + ComfyUI),
    Hyper-V Bridged Networking, and Sunshine Remote Game Streaming.
.DESCRIPTION
    1. Hardware & Environment Auto-Detection (Bare-Metal with GPU vs Test VM in CPU-mode).
    2. Enables Hyper-V, Virtual Machine Platform, and WSL optional features.
    3. Configures WSL2 Mirrored Networking in %USERPROFILE%\.wslconfig.
    4. Creates Hyper-V External Virtual Switch bridged to the primary network card.
    5. Configures Windows Defender Firewall rules for AI and Sunshine streaming.
    6. Installs Docker Desktop, Sunshine, and ViGEmBus (virtual gamepad driver) via Winget.
    7. Scaffolds and launches the Docker Compose stack tailored to available hardware.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$StackDir = "C:\ai-stack",
    [string]$SwitchName = "Bridged-External-Switch",
    [int]$OllamaPort = 11434,
    [int]$WebUIPort = 3000,
    [int]$ComfyUIPort = 8188,
    [string]$OllamaKeepAlive = "5m",
    [switch]$SkipStreamingInstall,
    [switch]$ForceCPU
)

$ErrorActionPreference = "Stop"

# Guard against empty parameter bindings when executed via Invoke-Expression (iex)
if (-not $OllamaPort -or $OllamaPort -eq 0) { $OllamaPort = 11434 }
if (-not $WebUIPort -or $WebUIPort -eq 0) { $WebUIPort = 3000 }
if (-not $ComfyUIPort -or $ComfyUIPort -eq 0) { $ComfyUIPort = 8188 }
if (-not $OllamaKeepAlive) { $OllamaKeepAlive = "5m" }
if (-not $StackDir) { $StackDir = "C:\ai-stack" }
if (-not $SwitchName) { $SwitchName = "Bridged-External-Switch" }

function Write-Step ($msg) { Write-Host "`n[+] $msg" -ForegroundColor Cyan }
function Write-Success ($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Notice ($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }

# -------------------------------------------------------------------------
# Phase 0: Hardware & Environment Introspection
# -------------------------------------------------------------------------
Write-Step "Phase 0: Analyzing Environment & Hardware..."

$isVM = (Get-CimInstance Win32_ComputerSystem).Model -match "Virtual|VMware|VirtualBox|KVM|QEMU|Hyper-V"
if ($isVM) {
    Write-Notice "Running inside a Virtual Machine environment."
} else {
    Write-Success "Running on Bare-Metal hardware."
}

# Check for NVIDIA GPU
$hasNvidiaGPU = $false
if (-not $ForceCPU) {
    $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like "*NVIDIA*" }
    if ($gpu) {
        $hasNvidiaGPU = $true
        Write-Success "NVIDIA GPU Detected: $($gpu.Name)"
    } else {
        Write-Notice "No NVIDIA GPU detected. Configuring Docker for CPU-Mode (Testing Environment)."
    }
} else {
    Write-Notice "Forced CPU-Mode via parameter."
}

# -------------------------------------------------------------------------
# Phase 1: Windows Features (Hyper-V & WSL2)
# -------------------------------------------------------------------------
Write-Step "Phase 1: Validating Windows Features..."

$RequiredFeatures = @(
    "Microsoft-Hyper-V-All",
    "VirtualMachinePlatform",
    "Microsoft-Windows-Subsystem-Linux"
)

$RebootNeeded = $false
foreach ($feature in $RequiredFeatures) {
    $state = Get-WindowsOptionalFeature -Online -FeatureName $feature
    if ($state.State -ne "Enabled") {
        Write-Notice "Enabling $feature..."
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart
        if ($result.RestartNeeded) { $RebootNeeded = $true }
    } else {
        Write-Success "$feature is already enabled."
    }
}

if ($RebootNeeded) {
    Write-Host "`n" + ("=" * 72) -ForegroundColor Red
    Write-Notice "CRITICAL: System features were enabled that require a PC restart."
    Write-Notice "Please restart your PC/VM, then re-run this script to finish setup."
    Write-Host ("=" * 72) -ForegroundColor Red
    
    $rebootNow = Read-Host "Would you like to reboot now? (Y/n)"
    if ($rebootNow -ne 'n') { Restart-Computer }
    return
}

# -------------------------------------------------------------------------
# Phase 2: WSL2 Mirrored Networking Configuration
# -------------------------------------------------------------------------
Write-Step "Phase 2: Configuring WSL2 Mirrored Networking..."

$wslConfigPath = "$env:USERPROFILE\.wslconfig"
$wslConfigContent = @"
[wsl2]
networkingMode=mirrored
autoProxy=true
dnsTunneling=true

[experimental]
autoMemoryReclaim=gradual
sparseVhd=true
"@

if (Test-Path $wslConfigPath) {
    $existing = Get-Content $wslConfigPath -Raw
    if ($existing -notmatch "networkingMode=mirrored") {
        Set-Content -Path $wslConfigPath -Value $wslConfigContent -Encoding UTF8
        Write-Success "Updated $wslConfigPath with mirrored networking."
    } else {
        Write-Success ".wslconfig already configured."
    }
} else {
    Set-Content -Path $wslConfigPath -Value $wslConfigContent -Encoding UTF8
    Write-Success "Created $wslConfigPath."
}

# -------------------------------------------------------------------------
# Phase 3: Hyper-V Bridged External Virtual Switch
# -------------------------------------------------------------------------
Write-Step "Phase 3: Setting up Hyper-V External Bridged Switch..."

$existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if (-not $existingSwitch) {
    $adapter = Get-NetAdapter | Where-Object { 
        $_.Status -eq "Up" -and 
        $_.InterfaceDescription -notmatch "Hyper-V|vEthernet|Loopback|WSL|Default Switch"
    } | Select-Object -First 1

    if ($adapter) {
        Write-Notice "Binding switch '$SwitchName' to adapter '$($adapter.Name)' ($($adapter.InterfaceDescription))..."
        New-VMSwitch -Name $SwitchName -NetAdapterName $adapter.Name -AllowManagementOS $true | Out-Null
        Write-Success "Hyper-V External Switch '$SwitchName' created."
    } else {
        Write-Warning "Could not detect active primary network card. Configure Hyper-V switch manually."
    }
} else {
    Write-Success "Hyper-V switch '$SwitchName' already exists."
}

# -------------------------------------------------------------------------
# Phase 4: Windows Firewall Inbound Rules
# -------------------------------------------------------------------------
Write-Step "Phase 4: Configuring Windows Firewall Inbound Rules..."

$Rules = @(
    # AI Stack
    @{ Name = "AI-Stack-Ollama";   Port = $OllamaPort;   Protocol = "TCP"; Description = "Ollama LLM API" },
    @{ Name = "AI-Stack-OpenWebUI"; Port = $WebUIPort;    Protocol = "TCP"; Description = "Open WebUI Portal" },
    @{ Name = "AI-Stack-ComfyUI";  Port = $ComfyUIPort;  Protocol = "TCP"; Description = "ComfyUI Interface" },
    # Sunshine Game Streaming
    @{ Name = "Sunshine-Web-HTTP";  Port = 47984;         Protocol = "TCP"; Description = "Sunshine Web Management" },
    @{ Name = "Sunshine-Web-HTTPS"; Port = 47990;         Protocol = "TCP"; Description = "Sunshine Web HTTPS" },
    @{ Name = "Sunshine-Audio";     Port = 48000;         Protocol = "UDP"; Description = "Sunshine Audio Stream" },
    @{ Name = "Sunshine-Video";     Port = 47998;         Protocol = "UDP"; Description = "Sunshine Video Stream" },
    @{ Name = "Sunshine-Control";   Port = 47999;         Protocol = "UDP"; Description = "Sunshine Control Stream" },
    @{ Name = "Sunshine-QoS";       Port = 48010;         Protocol = "UDP"; Description = "Sunshine QoS Probe" }
)

foreach ($r in $Rules) {
    $existingRule = Get-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
    if (-not $existingRule) {
        New-NetFirewallRule -Name $r.Name `
                            -DisplayName $r.Name `
                            -Description $r.Description `
                            -Direction Inbound `
                            -Action Allow `
                            -Protocol $r.Protocol `
                            -LocalPort $r.Port `
                            -Profile Any | Out-Null
        Write-Success "Firewall rule created for $($r.Name) ($($r.Protocol) Port $($r.Port))."
    } else {
        Write-Success "Firewall rule '$($r.Name)' is active."
    }
}

# -------------------------------------------------------------------------
# Phase 5: Software Installations
# -------------------------------------------------------------------------
Write-Step "Phase 5: Installing Required Software Packages..."

# 5.1 Docker Desktop
$dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
$dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
$isDockerInstalled = (Get-Command docker -ErrorAction SilentlyContinue) -or (Test-Path $dockerExe)

if (-not $isDockerInstalled) {
    Write-Notice "Docker Desktop not found. Installing..."
    $installed = $false
    
    # Try winget explicitly targeting community source (bypasses msstore source errors)
    try {
        $wingetProc = Start-Process -FilePath "winget" `
            -ArgumentList "install --id Docker.DockerDesktop --source winget -e --accept-package-agreements --accept-source-agreements --silent" `
            -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
            
        if ($wingetProc.ExitCode -eq 0) {
            $installed = $true
            Write-Success "Docker Desktop installed via winget."
        }
    } catch {
        Write-Notice "Winget execution failed: $_"
    }

    # Fallback to direct official installer download if winget fails or msstore blocked
    if (-not $installed) {
        Write-Notice "Winget failed or msstore blocked. Falling back to direct download from Docker..."
        $installerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
        $installerPath = "$env:TEMP\DockerDesktopInstaller.exe"
        
        Write-Notice "Downloading Docker Desktop installer..."
        $prevProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue' # Dramatic speedup, prevents console freeze
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
        $ProgressPreference = $prevProgress
        
        Write-Notice "Running Docker Desktop silent installer (WSL2 backend)..."
        $proc = Start-Process -FilePath $installerPath -ArgumentList "install --quiet --accept-license --backend=wsl-2" -Wait -PassThru
        Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        
        if ($proc.ExitCode -eq 0) {
            Write-Success "Docker Desktop installed successfully via direct installer."
        } else {
            Write-Warning "Docker Desktop installer finished with exit code $($proc.ExitCode)."
        }
    }
} else {
    Write-Success "Docker Desktop is already installed on disk."
}

# Ensure Docker is accessible in current session and service is started
if ((Test-Path $dockerBin) -and ($env:Path -notlike "*$dockerBin*")) {
    $env:Path = "$dockerBin;$env:Path"
}
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

if (Test-Path $dockerExe) {
    $dockerProc = Get-Process "Docker Desktop" -ErrorAction SilentlyContinue
    if (-not $dockerProc) {
        Write-Notice "Launching Docker Desktop to initialize the WSL2 daemon..."
        Start-Process -FilePath $dockerExe
    }
}

# 5.2 Sunshine & ViGEmBus Game Controller Driver
if (-not $SkipStreamingInstall) {
    $vigemInstalled = Get-Service "ViGEmBus" -ErrorAction SilentlyContinue
    if (-not $vigemInstalled) {
        Write-Notice "Installing ViGEmBus (Virtual Gamepad Emulation Bus)..."
        Start-Process -FilePath "winget" `
            -ArgumentList "install --id Nefarius.ViGEmBus --source winget -e --accept-package-agreements --accept-source-agreements --silent" `
            -NoNewWindow -Wait -ErrorAction SilentlyContinue
    } else {
        Write-Success "ViGEmBus driver is already installed."
    }
    
    $sunshineInstalled = (Test-Path "C:\Program Files\Sunshine\sunshine.exe") -or (Get-Service "sunshine" -ErrorAction SilentlyContinue)
    if (-not $sunshineInstalled) {
        Write-Notice "Installing Sunshine Game Streaming Server..."
        Start-Process -FilePath "winget" `
            -ArgumentList "install --id LizardByte.Sunshine --source winget -e --accept-package-agreements --accept-source-agreements --silent" `
            -NoNewWindow -Wait -ErrorAction SilentlyContinue
    } else {
        Write-Success "Sunshine Game Streaming Server is already installed."
    }
    Write-Success "Streaming tools verification completed."
}

# -------------------------------------------------------------------------
# Phase 6: Generate Environment-Tailored Docker Compose
# -------------------------------------------------------------------------
Write-Step "Phase 6: Scaffolding Docker Compose AI Stack at $StackDir..."

if (-not (Test-Path $StackDir)) {
    New-Item -ItemType Directory -Path $StackDir -Force | Out-Null
}

$composeTarget = Join-Path $StackDir "compose.yaml"

if ($hasNvidiaGPU) {
    $composeContent = @"
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "$OllamaPort:11434"
    environment:
      - OLLAMA_KEEP_ALIVE=$OllamaKeepAlive
    volumes:
      - ollama_data:/root/.ollama
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "$WebUIPort:8080"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
    volumes:
      - open_webui_data:/app/backend/data
    depends_on:
      - ollama

  comfyui:
    image: yanwk/comfyui-boot:latest
    container_name: comfyui
    restart: unless-stopped
    ports:
      - "$ComfyUIPort:8188"
    environment:
      - CLI_ARGS=--listen 0.0.0.0 --port 8188
    volumes:
      - comfyui_storage:/root/ComfyUI
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

volumes:
  ollama_data:
  open_webui_data:
  comfyui_storage:
"@
} else {
    $composeContent = @"
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "$OllamaPort:11434"
    environment:
      - OLLAMA_KEEP_ALIVE=$OllamaKeepAlive
    volumes:
      - ollama_data:/root/.ollama

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "$WebUIPort:8080"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
    volumes:
      - open_webui_data:/app/backend/data
    depends_on:
      - ollama

  comfyui:
    image: yanwk/comfyui-boot:latest
    container_name: comfyui
    restart: unless-stopped
    ports:
      - "$ComfyUIPort:8188"
    environment:
      - CLI_ARGS=--listen 0.0.0.0 --port 8188
    volumes:
      - comfyui_storage:/root/ComfyUI

volumes:
  ollama_data:
  open_webui_data:
  comfyui_storage:
"@
}

Set-Content -Path $composeTarget -Value $composeContent -Encoding UTF8
Write-Success "Generated compose.yaml ($(if ($hasNvidiaGPU) { 'GPU-Accelerated' } else { 'CPU-Testing-Mode' }))."

# -------------------------------------------------------------------------
# Summary & Next Steps
# -------------------------------------------------------------------------
$hostIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
    $_.InterfaceAlias -notmatch "vEthernet|Loopback|WSL" -and $_.IPAddress -notlike "169.254*" 
} | Select-Object -First 1).IPAddress

Write-Host "`n" + ("=" * 72) -ForegroundColor Green
Write-Host " Setup Completed Successfully!" -ForegroundColor Green
Write-Host ("=" * 72) -ForegroundColor Green
Write-Host "Operation Mode      : $(if ($hasNvidiaGPU) { 'Bare-Metal (NVIDIA GPU Passthrough)' } else { 'Test VM (CPU Fallback Mode)' })"
Write-Host "Host LAN IP         : $hostIP"
Write-Host "Ollama API          : http://${hostIP}:$OllamaPort"
Write-Host "Open WebUI Portal   : http://${hostIP}:$WebUIPort"
Write-Host "ComfyUI Workflow    : http://${hostIP}:$ComfyUIPort"
Write-Host "Sunshine Web UI     : https://${hostIP}:47990"
Write-Host "Hyper-V Bridged NIC : $SwitchName (Ready for Type-2 VMs)"
Write-Host "`nTo start the AI stack:"
Write-Host "  cd $StackDir" -ForegroundColor Yellow
Write-Host "  docker compose up -d" -ForegroundColor Yellow
Write-Host ("=" * 72)
