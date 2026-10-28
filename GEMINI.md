# GEMINI.md - Windows 11 AI & Gaming Workstation Automation

## Project Purpose
Automated, zero-touch provisioning of a dual-use Windows 11 workstation capable of concurrently hosting:
1. **Containerized AI Services**: Ollama (LLM API), Open WebUI (RAG & chat portal), and ComfyUI (diffusion image/video pipeline) via Docker Desktop on WSL2 with NVIDIA GPU passthrough and automatic VRAM reclamation.
2. **Native PC Gaming & Remote Streaming**: Ultra-low latency game streaming via Sunshine and ViGEmBus (virtual gamepad emulation) to Moonlight clients (Mac, TV, mobile) utilizing hardware NVENC encoding.
3. **Type-2 Virtualization Lab**: Hyper-V with an External Virtual Switch bridged to the physical network adapter, providing lab VMs with native DHCP IP addresses alongside the host.

## Architecture Overview
- **Host OS**: Windows 11 Pro/Enterprise (Bare-metal with NVIDIA GPU, or test VM in CPU-mode).
- **Automation Engine**: PowerShell (5.1 / 7+) utilizing native cmdlets, DISM, and `winget`.
- **Containers**: Docker Desktop running on the WSL2 backend with Mirrored Networking mode (`networkingMode=mirrored`) to expose ports on the host's LAN IP.
- **Remote Streaming**: Sunshine service capturing DirectX/Vulkan frames, encoding via NVENC ASIC, and receiving controller signals translated through ViGEmBus.

## Key Directory & File Structure
```text
win11-ai-gaming-rig/
├── Setup-Rig.ps1          # Master idempotent orchestrator
├── Install-Streaming.ps1  # Dedicated Sunshine + ViGEmBus installer
├── compose.yaml           # Multi-service AI stack (Ollama + Open WebUI + ComfyUI)
├── README.md              # Operator instructions and one-liner bootstrap commands
├── GEMINI.md              # Project context and architectural blueprint
├── LEARNINGS.gemini.md    # PRAR execution and learnings log
└── docs/
    ├── architecture-design-document.md
    ├── technical-design-document.md
    ├── software-requirements-specification.md
    ├── product-requirements-document.md
    └── backlog.md
```

## Setup & Execution
Run directly on Windows 11 in an elevated PowerShell session (`Administrator`):
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Setup-Rig.ps1
```
