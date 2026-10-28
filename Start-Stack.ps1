<#
.SYNOPSIS
    Convenience helper to refresh PATH, ensure Docker Desktop is running, and launch the AI Stack.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = "Continue"

Write-Host "==> Refreshing session PATH environment variable..." -ForegroundColor Cyan
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
$dockerBin = "C:\Program Files\Docker\Docker\resources\bin"
if (Test-Path $dockerBin -and ($env:Path -notlike "*$dockerBin*")) {
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
if (-not (Test-Path "$stackDir\compose.yaml")) {
    Write-Error "Could not find $stackDir\compose.yaml. Run Setup-Rig.ps1 first."
    return
}

Write-Host "==> Launching Docker Compose AI Stack..." -ForegroundColor Cyan
Set-Location $stackDir
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
