# Windows 11 AI Rig, Game Streaming & Hyper-V Automation

Automated provisioning for a dual-use Windows 11 workstation running an AI stack, low-latency game streaming, and bridged Hyper-V VMs — from a single PowerShell command.

---

## Repository Structure

```text
win11-ai-gaming-rig/
├── Setup-Rig.ps1     # Run ONCE on a new machine to provision everything
├── Start-Stack.ps1   # Run ANYTIME to start or restart the AI stack
├── compose.gpu.yaml  # Docker stack with NVIDIA GPU passthrough
├── compose.cpu.yaml  # Docker stack in CPU mode (for VM testing)
└── docs/             # Architecture and design documents
```

---

## Quick Start

Open **Windows PowerShell (Run as Administrator)** and paste:

```powershell
# First-time machine setup:
irm "https://raw.githubusercontent.com/kiprotichgidii/win11-ai-gaming-rig/main/Setup-Rig.ps1?$(Get-Random)" | iex
```

```powershell
# Start or restart the stack at any time:
irm "https://raw.githubusercontent.com/kiprotichgidii/win11-ai-gaming-rig/main/Start-Stack.ps1?$(Get-Random)" | iex
```

> **Note:** The `?$(Get-Random)` suffix bypasses GitHub's CDN cache (5-min TTL) so you always get the latest version.

---

## What `Setup-Rig.ps1` Does

| Phase | Action |
| :--- | :--- |
| **0** | Detects NVIDIA GPU — auto-selects GPU or CPU mode |
| **1** | Enables Hyper-V, VirtualMachinePlatform, and WSL2 features |
| **2** | Configures WSL2 mirrored networking and pins permanent public DNS (8.8.8.8) |
| **3** | Creates a Hyper-V external virtual switch bridged to the physical NIC |
| **4** | Opens inbound firewall rules for Ollama, Open WebUI, ComfyUI, and Sunshine |
| **5** | Installs Docker Desktop, ViGEmBus (gamepad driver), and Sunshine via winget |
| **6** | Pulls and starts the Docker Compose AI stack |

> **Reboot Handling:** If Windows features are newly enabled, the script will prompt to reboot. Re-run it after restarting — it skips completed phases automatically.

---

## AI Stack Services

| Service | Port | Description |
| :--- | :--- | :--- |
| **Ollama** | `11434` | LLM inference engine (Llama, Qwen, DeepSeek) |
| **Open WebUI** | `3000` | ChatGPT-style interface with RAG and document Q&A |
| **ComfyUI** | `8188` | Node-based image/video generation (Stable Diffusion, Flux) |

---

## Client & IDE Integration (JetBrains / Android Studio)

```text
Native Ollama URL     : http://<Host-IP>:11434
OpenAI-Compatible URL : http://<Host-IP>:11434/v1
API Key               : ollama  (or leave blank)
```

Pull a coding model after setup:
```powershell
docker exec -it ollama ollama pull qwen2.5-coder:7b
```

---

## Game Streaming

Sunshine runs as a Windows service on the host. Connect from any client using [Moonlight](https://moonlight-stream.org):

| | |
| :--- | :--- |
| **Sunshine Admin** | `https://<Host-IP>:47990` |
| **Moonlight** | Auto-discovers host on LAN — enter 4-digit PIN once |

---

## VRAM Management During Gaming

Ollama auto-releases VRAM after 5 minutes of idle. For ComfyUI:
```powershell
docker stop comfyui   # Free VRAM before gaming
docker start comfyui  # Resume after gaming
```

---

## Troubleshooting

| Problem | Fix |
| :--- | :--- |
| `docker: not recognized` | `$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")` |
| Images fail to resolve | Run `Setup-Rig.ps1` again — it pins WSL2 DNS to 8.8.8.8 permanently |
| Docker Hub rate limited | `docker login` with a free Docker Hub account |
| Port error in compose | Run `Start-Stack.ps1` — it always writes a clean compose.yaml |
| VM testing (no GPU) | Script auto-detects and uses `compose.cpu.yaml` |
