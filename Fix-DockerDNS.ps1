<#
.SYNOPSIS
    Fixes Docker Desktop and WSL2 DNS resolution issues on Windows 11.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = "Continue"

Write-Host "==> Step 1: Testing Windows Host Internet & DNS..." -ForegroundColor Cyan
$dnsTest = Resolve-DnsName "registry-1.docker.io" -ErrorAction SilentlyContinue
if ($dnsTest) {
    Write-Host "[OK] Windows Host DNS is working properly." -ForegroundColor Green
} else {
    Write-Warning "Windows host itself cannot resolve registry-1.docker.io. Check your host network/internet connection."
}

Write-Host "==> Step 2: Injecting Public DNS (8.8.8.8, 1.1.1.1) into Docker Desktop daemon..." -ForegroundColor Cyan
$dockerConfigDir = "$env:USERPROFILE\.docker"
if (-not (Test-Path $dockerConfigDir)) {
    New-Item -ItemType Directory -Path $dockerConfigDir -Force | Out-Null
}

$daemonJsonPath = Join-Path $dockerConfigDir "daemon.json"
$config = @{}
if (Test-Path $daemonJsonPath) {
    try {
        $raw = Get-Content $daemonJsonPath -Raw
        if ($raw.Trim()) {
            $config = $raw | ConvertFrom-Json -AsHashtable
        }
    } catch {
        $config = @{}
    }
}
$config["dns"] = @("8.8.8.8", "1.1.1.1")
$config | ConvertTo-Json -Depth 5 | Set-Content -Path $daemonJsonPath -Encoding UTF8
Write-Host "[OK] Docker daemon.json updated at $daemonJsonPath." -ForegroundColor Green

Write-Host "==> Step 3: Injecting Public DNS into WSL2 /etc/resolv.conf..." -ForegroundColor Cyan
if (Get-Command wsl -ErrorAction SilentlyContinue) {
    try {
        wsl -u root -e sh -c "echo 'nameserver 8.8.8.8' > /etc/resolv.conf && echo 'nameserver 1.1.1.1' >> /etc/resolv.conf"
        Write-Host "[OK] WSL2 /etc/resolv.conf updated." -ForegroundColor Green
    } catch {
        Write-Warning "WSL command failed: $_"
    }
}

Write-Host "==> Step 4: Restarting Docker Desktop to apply new DNS..." -ForegroundColor Cyan
Get-Process "Docker Desktop", "com.docker.backend", "dockerd" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$dockerExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
if (Test-Path $dockerExe) {
    Start-Process -FilePath $dockerExe
    Write-Host "Waiting for Docker daemon to restart..." -ForegroundColor Yellow
    $retries = 35
    while ($retries -gt 0) {
        docker info >$null 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 2
        $retries--
    }
}

Write-Host "==> Step 5: Testing image pull resolution..." -ForegroundColor Cyan
docker pull hello-world
if ($LASTEXITCODE -eq 0) {
    Write-Host "`n[SUCCESS] Docker DNS resolution is fully fixed!" -ForegroundColor Green
    Write-Host "Now pulling AI stack images..." -ForegroundColor Cyan
    Set-Location "C:\ai-stack"
    docker compose pull
    docker compose up -d
} else {
    Write-Warning "Docker pull still failing. Please check if your VM has an active outbound internet connection."
}
