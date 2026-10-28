<#
.SYNOPSIS
    Diagnoses and fixes Ollama image pull failures specifically.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = "Continue"

function Write-Step ($msg) { Write-Host "`n[+] $msg" -ForegroundColor Cyan }
function Write-OK   ($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "[!]  $msg" -ForegroundColor Yellow }

# -------------------------------------------------------------------------
# Step 1: Check WSL2 disk space (Ollama image is ~1.5GB)
# -------------------------------------------------------------------------
Write-Step "Step 1: Checking available disk space in WSL2..."
$wslDisk = wsl -u root -e df -h / 2>$null
Write-Host $wslDisk

$dockerDisk = docker system df 2>$null
Write-Host $dockerDisk

# Check Windows drive free space
$drive = Get-PSDrive C
$freeGB = [math]::Round($drive.Free / 1GB, 2)
Write-Host "Windows C:\ free space: $freeGB GB"
if ($freeGB -lt 5) {
    Write-Warn "Low disk space on C:\! Ollama image needs ~1.5GB, Open WebUI ~1GB, ComfyUI ~8GB."
    Write-Warn "Free up disk space before pulling."
}

# -------------------------------------------------------------------------
# Step 2: Check Docker Hub rate limit status
# -------------------------------------------------------------------------
Write-Step "Step 2: Checking Docker Hub rate limit..."
try {
    $token = (Invoke-RestMethod "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" -UseBasicParsing).token
    $headers = @{ Authorization = "Bearer $token" }
    $rateCheck = Invoke-WebRequest "https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest" `
        -Headers $headers -Method HEAD -UseBasicParsing -ErrorAction SilentlyContinue
    $limit     = $rateCheck.Headers["RateLimit-Limit"]
    $remaining = $rateCheck.Headers["RateLimit-Remaining"]
    if ($remaining) {
        Write-Host "Docker Hub Rate Limit : $limit"
        Write-Host "Pulls Remaining       : $remaining"
        if ([int]($remaining -split ";")[0] -lt 5) {
            Write-Warn "RATE LIMITED: Almost no pulls remaining on this IP."
            Write-Warn "Solution: Log in to Docker Hub (free account) to get 200 pulls/6h."
        } else {
            Write-OK "Rate limit is fine."
        }
    }
} catch {
    Write-Warn "Could not check rate limit: $_"
}

# -------------------------------------------------------------------------
# Step 3: Try pulling Ollama directly with verbose output
# -------------------------------------------------------------------------
Write-Step "Step 3: Attempting Ollama image pull with verbose output..."
Write-Warn "This may take several minutes (image is ~1.5GB)..."
docker pull ollama/ollama:latest 2>&1 | Tee-Object -Variable ollamaOutput
if ($LASTEXITCODE -eq 0) {
    Write-OK "Ollama image pulled successfully!"
    
    # Pull remaining images
    Write-Step "Step 4: Pulling Open WebUI..."
    docker pull ghcr.io/open-webui/open-webui:main

    Write-Step "Step 5: Pulling ComfyUI..."
    docker pull yanwk/comfyui-boot:latest

    # Launch stack
    Write-Step "Step 6: Starting AI stack..."
    $stackDir = "C:\ai-stack"
    $hasNvidiaGPU = [bool](Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like "*NVIDIA*" })

    if ($hasNvidiaGPU) {
        $yaml = @"
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
    image: yanwk/comfyui-boot:latest
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
        $yaml = @"
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
    image: yanwk/comfyui-boot:latest
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

    if (-not (Test-Path $stackDir)) { New-Item -ItemType Directory -Path $stackDir -Force | Out-Null }
    Set-Content -Path "$stackDir\compose.yaml" -Value $yaml -Encoding UTF8
    Set-Location $stackDir
    docker compose up -d
    docker compose ps

    $hostIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.InterfaceAlias -notmatch "vEthernet|Loopback|WSL" -and $_.IPAddress -notlike "169.254*"
    } | Select-Object -First 1).IPAddress

    Write-Host "`n=======================================================" -ForegroundColor Green
    Write-Host " AI Stack is live!"
    Write-Host "  Open WebUI : http://${hostIP}:3000"
    Write-Host "  ComfyUI    : http://${hostIP}:8188"
    Write-Host "  Ollama API : http://${hostIP}:11434"
    Write-Host "=======================================================" -ForegroundColor Green

} else {
    Write-Warn "Ollama pull failed. Error details:"
    Write-Host ($ollamaOutput -join "`n") -ForegroundColor Red

    Write-Host ""
    Write-Host "=======================================================" -ForegroundColor Yellow
    Write-Host " DIAGNOSIS & NEXT STEPS" -ForegroundColor Yellow
    Write-Host "=======================================================" -ForegroundColor Yellow
    Write-Host "1. Rate Limited by Docker Hub?"
    Write-Host "   Fix: Log in with a free Docker Hub account:"
    Write-Host "   docker login" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "2. Image too large for WSL2 virtual disk?"
    Write-Host "   Fix: Expand WSL2 disk:"
    Write-Host "   wsl --manage docker-desktop --set-sparse true" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "3. GHCR (Open WebUI) behind a firewall?"
    Write-Host "   Fix: Test ghcr.io separately:"
    Write-Host "   docker pull ghcr.io/open-webui/open-webui:main" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "4. Try Docker Hub login to remove rate limit:"
    Write-Host "   docker login -u <your-dockerhub-username>" -ForegroundColor Cyan
}
