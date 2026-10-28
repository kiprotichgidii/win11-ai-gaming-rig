<#
.SYNOPSIS
    Permanently fixes Docker/WSL2 DNS resolution so image pulls succeed.
.DESCRIPTION
    1. Diagnoses Windows host DNS.
    2. Permanently disables WSL2 auto-generated resolv.conf so public DNS survives reboots.
    3. Injects 8.8.8.8 / 1.1.1.1 into Docker daemon.json.
    4. Restarts WSL2 and Docker daemon to apply changes.
    5. Validates with a test pull then launches the full AI stack.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = "Continue"

function Write-Step ($msg) { Write-Host "`n[+] $msg" -ForegroundColor Cyan }
function Write-OK   ($msg) { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "[!]  $msg" -ForegroundColor Yellow }

# -------------------------------------------------------------------------
# Step 1: Diagnose Windows host internet & DNS
# -------------------------------------------------------------------------
Write-Step "Step 1: Diagnosing Windows host DNS..."
try {
    $dnsResult = Resolve-DnsName "registry-1.docker.io" -ErrorAction Stop
    Write-OK "Windows host can resolve registry-1.docker.io -> $($dnsResult[0].IPAddress)"
} catch {
    Write-Warn "Windows host CANNOT resolve registry-1.docker.io."
    Write-Warn "Check your VM's network adapter and internet connection first."
    Write-Host "Press Enter to continue anyway, or Ctrl+C to abort..."
    Read-Host | Out-Null
}

# -------------------------------------------------------------------------
# Step 2: Permanently fix WSL2 DNS (survives reboots)
# -------------------------------------------------------------------------
Write-Step "Step 2: Permanently fixing WSL2 DNS resolution..."

if (Get-Command wsl -ErrorAction SilentlyContinue) {
    # 2a: Disable WSL2's auto-generation of resolv.conf
    Write-Warn "Disabling WSL2 auto-generated resolv.conf..."
    wsl -u root -e sh -c @"
cat > /etc/wsl.conf << 'EOF'
[network]
generateResolvConf = false
EOF
"@

    # 2b: Write permanent public DNS nameservers
    Write-Warn "Writing permanent DNS nameservers to /etc/resolv.conf..."
    wsl -u root -e sh -c @"
rm -f /etc/resolv.conf
cat > /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 8.8.4.4
EOF
"@

    # 2c: Shut down WSL2 completely so changes take effect on next start
    Write-Warn "Shutting down WSL2 to apply DNS changes..."
    wsl --shutdown
    Start-Sleep -Seconds 5

    # 2d: Verify DNS inside WSL2 is working
    Write-Warn "Verifying DNS resolution inside WSL2..."
    $wslDns = wsl -u root -e nslookup registry-1.docker.io 2>&1
    if ($wslDns -match "Address") {
        Write-OK "WSL2 DNS is now working: registry-1.docker.io resolves correctly."
    } else {
        Write-Warn "WSL2 DNS test inconclusive. Output: $wslDns"
    }
} else {
    Write-Warn "WSL not found on PATH. Skipping WSL2 DNS fix."
}

# -------------------------------------------------------------------------
# Step 3: Inject public DNS into Docker daemon.json
# -------------------------------------------------------------------------
Write-Step "Step 3: Configuring Docker daemon to use public DNS..."

$dockerConfigDir = "$env:USERPROFILE\.docker"
if (-not (Test-Path $dockerConfigDir)) {
    New-Item -ItemType Directory -Path $dockerConfigDir -Force | Out-Null
}

$daemonJsonPath = Join-Path $dockerConfigDir "daemon.json"
$daemonConfig = @{
    "dns"             = @("8.8.8.8", "1.1.1.1", "8.8.4.4")
    "dns-search"      = @(".")
}

$daemonConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $daemonJsonPath -Encoding UTF8
Write-OK "Docker daemon.json written to $daemonJsonPath"

# -------------------------------------------------------------------------
# Step 4: Restart Docker Desktop cleanly
# -------------------------------------------------------------------------
Write-Step "Step 4: Restarting Docker Desktop..."

Get-Process "Docker Desktop", "com.docker.backend", "dockerd", "docker" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

$dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if (Test-Path $dockerExe) {
    Start-Process -FilePath $dockerExe
    Write-Warn "Waiting for Docker daemon to become ready (up to 60s)..."
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        $info = docker info 2>$null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if ($ready) {
        Write-OK "Docker daemon is running."
    } else {
        Write-Warn "Docker daemon did not respond in time. Check Docker Desktop."
    }
} else {
    Write-Warn "Docker Desktop executable not found. Skipping restart."
}

# -------------------------------------------------------------------------
# Step 5: Validate Docker pull against registry
# -------------------------------------------------------------------------
Write-Step "Step 5: Validating Docker registry connectivity..."

docker pull hello-world 2>&1 | Tee-Object -Variable pullOutput
if ($LASTEXITCODE -eq 0) {
    Write-OK "Docker can reach Docker Hub and pull images successfully."
    docker rmi hello-world -f 2>$null
} else {
    Write-Warn "Docker pull still failing. Full output:"
    Write-Host ($pullOutput -join "`n") -ForegroundColor Red
    Write-Warn "Possible causes:"
    Write-Host "  - VM has no outbound internet access (check VM network adapter is Bridged or NAT)"
    Write-Host "  - Corporate proxy blocking Docker Hub"
    Write-Host "  - Docker Desktop is still in Windows Container mode"
    Write-Host "Run: docker info --format '{{.OSType}}' -- must return 'linux'"
    return
}

# -------------------------------------------------------------------------
# Step 6: Write clean compose.yaml and launch stack
# -------------------------------------------------------------------------
Write-Step "Step 6: Writing clean compose.yaml and launching AI stack..."

$hasNvidiaGPU = [bool](Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like "*NVIDIA*" })
$stackDir = "C:\ai-stack"
if (-not (Test-Path $stackDir)) { New-Item -ItemType Directory -Path $stackDir -Force | Out-Null }

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

Set-Content -Path "$stackDir\compose.yaml" -Value $yaml -Encoding UTF8
Write-OK "compose.yaml written ($(if ($hasNvidiaGPU) { 'GPU mode' } else { 'CPU mode' }))."

Set-Location $stackDir
Write-Warn "Pulling images..."
docker compose pull
docker compose up -d

Write-Host ""
docker compose ps

$hostIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
    $_.InterfaceAlias -notmatch "vEthernet|Loopback|WSL" -and $_.IPAddress -notlike "169.254*"
} | Select-Object -First 1).IPAddress

Write-Host "`n=======================================================" -ForegroundColor Green
Write-Host " AI Stack is live!" -ForegroundColor Green
Write-Host "  Open WebUI : http://${hostIP}:3000"
Write-Host "  ComfyUI    : http://${hostIP}:8188"
Write-Host "  Ollama API : http://${hostIP}:11434"
Write-Host "=======================================================" -ForegroundColor Green
