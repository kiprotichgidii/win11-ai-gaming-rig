<#
.SYNOPSIS
    Standalone installer for Sunshine Game Streaming and ViGEmBus controller driver.
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

Write-Host "==> Installing ViGEmBus (Virtual Gamepad Emulation Bus)..." -ForegroundColor Cyan
winget install --id Nefarius.ViGEmBus --source winget -e --accept-package-agreements --accept-source-agreements --silent

Write-Host "==> Installing Sunshine Game Streaming Server..." -ForegroundColor Cyan
winget install --id LizardByte.Sunshine --source winget -e --accept-package-agreements --accept-source-agreements --silent

Write-Host "==> Configuring Inbound Firewall Rules for Sunshine..." -ForegroundColor Cyan
$SunshineRules = @(
    @{ Name = "Sunshine-Web-HTTP";    Port = 47984; Protocol = "TCP" },
    @{ Name = "Sunshine-Web-HTTPS";   Port = 47990; Protocol = "TCP" },
    @{ Name = "Sunshine-Audio";       Port = 48000; Protocol = "UDP" },
    @{ Name = "Sunshine-Video";       Port = 47998; Protocol = "UDP" },
    @{ Name = "Sunshine-Control";     Port = 47999; Protocol = "UDP" },
    @{ Name = "Sunshine-QoS";         Port = 48010; Protocol = "UDP" }
)

foreach ($r in $SunshineRules) {
    if (-not (Get-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $r.Name `
                            -DisplayName $r.Name `
                            -Direction Inbound `
                            -Action Allow `
                            -Protocol $r.Protocol `
                            -LocalPort $r.Port `
                            -Profile Any | Out-Null
        Write-Host "[OK] Firewall opened: $($r.Name) ($($r.Protocol) Port $($r.Port))" -ForegroundColor Green
    }
}

Write-Host "`nSunshine installation and firewall configuration complete!" -ForegroundColor Green
Write-Host "Admin Web UI: https://localhost:47990" -ForegroundColor Yellow
