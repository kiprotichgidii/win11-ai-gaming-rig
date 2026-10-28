<#
.SYNOPSIS
    Convenience helper to refresh PATH, ensure Docker Desktop is running, and launch the AI Stack.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = "Continue"

Write-Host "==> Refreshing session PATH environment variable..." -ForegroundColor Cyan
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
$dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
if ((Test-Path $dockerBin) -and ($env:Path -notlike "*$dockerBin*")) {
    $env:Path = "$dockerBin;$env:Path"
}

# Check if Docker Desktop executable exists
$dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    if (Test-Path $dockerExe) {
        Write-Host "Docker binary located at $dockerBin. Adding to session PATH." -ForegroundColor Green
    } else {
        Write-Error "Docker Desktop is not installed. Run Setup-Rig.ps1 first."
        return
    }
}

# Ensure Docker Desktop is running
$dockerProc = Get-Process "Docker Desktop" -ErrorAction SilentlyContinue
if (-not $dockerProc) {
    Write-Host "==> Starting Docker Desktop service..." -ForegroundColor Cyan
    Start-Process -FilePath $dockerExe
    Write-Host "Waiting for Docker daemon to initialize (this can take 20-30s)..." -ForegroundColor Yellow
    $retries = 30
    while ($retries -gt 0) {
        docker info >$null 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 2
        $retries--
    }
}

# Launch the AI Stack
$stackDir = "C:\ai-stack"
if (-not (Test-Path $stackDir)) {
    New-Item -ItemType Directory -Path $stackDir -Force | Out-Null
}

# Auto-heal compose.yaml if corrupted or missing
$hasNvidiaGPU = [bool](Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like "*NVIDIA*" })
$composeFile = Join-Path $stackDir "compose.yaml"

if ($hasNvidiaGPU) {
    $cleanCompose = @"
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    environment:
      - OLLAMA_KEEP_ALIVE=5m
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
      - "3000:8080"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
    volumes:
      - open_webui_data:/app/backend/data
    depends_on:
      - ollama

  comfyui:
    image: yanwk/comfyui-boot:cu130-slim-v2
    container_name: comfyui
    restart: unless-stopped
    ports:
      - "8188:8188"
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
    $cleanCompose = @"
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "11434:11434"
    environment:
      - OLLAMA_KEEP_ALIVE=5m
    volumes:
      - ollama_data:/root/.ollama

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "3000:8080"
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
    volumes:
      - open_webui_data:/app/backend/data
    depends_on:
      - ollama

  comfyui:
    image: yanwk/comfyui-boot:cu130-slim-v2
    container_name: comfyui
    restart: unless-stopped
    ports:
      - "8188:8188"
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

Set-Content -Path $composeFile -Value $cleanCompose -Encoding UTF8
Write-Host "==> Verified compose.yaml at $composeFile ($(if ($hasNvidiaGPU) { 'GPU-Mode' } else { 'CPU-Mode' }))." -ForegroundColor Green

# Verify Docker engine OS type (Must be 'linux')
$osType = docker info --format '{{.OSType}}' 2>$null
if ($osType -and $osType -ne "linux") {
    Write-Warning "Docker Desktop is currently running in '$osType' containers mode!"
    Write-Host "Attempting to switch Docker Desktop to Linux containers..." -ForegroundColor Yellow
    $dockerCli = "C:\Program Files\Docker\Docker\DockerCli.exe"
    if (Test-Path $dockerCli) {
        & $dockerCli -SwitchLinuxEngine
        Start-Sleep -Seconds 10
    } else {
        Write-Error "Please right-click Docker Desktop in the system tray and select 'Switch to Linux containers...'."
        return
    }
}

# Ensure Docker daemon has working public DNS (avoids registry lookup failures)
$dockerConfigDir = "$env:USERPROFILE\.docker"
$daemonJsonPath = Join-Path $dockerConfigDir "daemon.json"
if (-not (Test-Path $dockerConfigDir)) { New-Item -ItemType Directory -Path $dockerConfigDir -Force | Out-Null }

$daemonUpdated = $false
$daemonConfig = @{}
if (Test-Path $daemonJsonPath) {
    try {
        $raw = Get-Content $daemonJsonPath -Raw
        if ($raw.Trim()) { $daemonConfig = $raw | ConvertFrom-Json -AsHashtable }
    } catch {}
}
if (-not $daemonConfig.ContainsKey("dns")) {
    $daemonConfig["dns"] = @("8.8.8.8", "1.1.1.1")
    $daemonConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $daemonJsonPath -Encoding UTF8
    $daemonUpdated = $true
}

# Update WSL resolv.conf if WSL is accessible
if (Get-Command wsl -ErrorAction SilentlyContinue) {
    try {
        wsl -u root -e sh -c "echo 'nameserver 8.8.8.8' > /etc/resolv.conf && echo 'nameserver 1.1.1.1' >> /etc/resolv.conf" 2>$null
    } catch {}
}

if ($daemonUpdated) {
    Write-Host "==> Configured public DNS for Docker daemon. Restarting Docker..." -ForegroundColor Yellow
    Get-Process "Docker Desktop", "com.docker.backend" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Start-Process -FilePath $dockerExe
    $retries = 35
    while ($retries -gt 0) {
        docker info >$null 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 2
        $retries--
    }
}

Write-Host "==> Pulling container images (this may take a few minutes depending on connection)..." -ForegroundColor Cyan
Set-Location $stackDir
docker compose pull

Write-Host "==> Launching Docker Compose AI Stack..." -ForegroundColor Cyan
docker compose up -d

Write-Host "`n==> Active Container Status:" -ForegroundColor Green
docker compose ps

$hostIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { 
    $_.InterfaceAlias -notmatch "vEthernet|Loopback|WSL" -and $_.IPAddress -notlike "169.254*" 
} | Select-Object -First 1).IPAddress

Write-Host "`n=======================================================" -ForegroundColor Green
Write-Host "Stack is live and reachable at:"
Write-Host "  Open WebUI : http://${hostIP}:3000"
Write-Host "  ComfyUI    : http://${hostIP}:8188"
Write-Host "  Ollama API : http://${hostIP}:11434"
Write-Host "=======================================================" -ForegroundColor Green
