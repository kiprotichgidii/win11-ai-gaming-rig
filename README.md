# Windows 11 AI Rig, Gaming Stream & Hyper-V Automation

Production-ready automation suite to provision a unified Windows 11 workstation capable of hosting:
1. **Containerized AI Services**: Ollama, Open WebUI, and ComfyUI running via Docker Desktop on WSL2 with native NVIDIA GPU acceleration.
2. **PC Game Streaming**: Ultra-low-latency, 4K/120Hz remote gaming via Sunshine to Moonlight clients with virtual controller passthrough (ViGEmBus).
3. **Type-2 Virtualization**: Hyper-V External Virtual Switch bridged to the physical network adapter.

---

## Quick Start: One-Liner Execution on Windows 11

You do **not** need Git pre-installed on the Windows machine. Open **Windows PowerShell (Run as Administrator)** and run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
irm https://raw.githubusercontent.com/<YOUR-USERNAME>/<YOUR-REPO>/main/Setup-Rig.ps1 | iex
```
*(Replace `<YOUR-USERNAME>` and `<YOUR-REPO>` with your GitHub repository path).*

---

## Alternative: Git Clone Execution

```powershell
# In PowerShell (Admin)
git clone https://github.com/<YOUR-USERNAME>/<YOUR-REPO>.git C:\Automate-Rig
cd C:\Automate-Rig
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Setup-Rig.ps1
```

---

## Reboot Handling

If Hyper-V, WSL2, or Virtual Machine Platform were not previously enabled on the target machine:
1. The script will enable them and prompt: `Would you like to reboot now? (Y/n)`.
2. Allow the reboot (`Y`).
3. After rebooting, re-open **PowerShell (Admin)** and re-run `.\Setup-Rig.ps1`.
4. It will automatically detect that features are active and complete the remaining phases.

---

## AI Stack Handoff (For Client / JetBrains Studio / Android Studio)

Provide these details to the client to configure their IDE or AI tools:

```text
======================================================================
              AI RIG & STUDIO INTEGRATION HANDOFF
======================================================================
1. STUDIO / IDE CONFIGURATION (JetBrains / Android Studio / Continue)
   - Protocol / Type      : Ollama / OpenAI-Compatible
   - Native Ollama URL    : http://<Host-IP>:11434
   - OpenAI Base URL      : http://<Host-IP>:11434/v1
   - API Key              : ollama (or leave blank)
   - Pre-installed Models : qwen2.5-coder:7b, llama3.1:8b

2. WEB MANAGEMENT PORTALS
   - Chat & Document RAG  : http://<Host-IP>:3000   (Open WebUI)
   - Image & Video UI     : http://<Host-IP>:8188   (ComfyUI)

3. REMOTE GAME STREAMING (Moonlight)
   - Host IP              : <Host-IP>
   - Sunshine Admin Panel : https://<Host-IP>:47990
======================================================================
```

To pre-load coding models on the rig:
```powershell
docker exec -it ollama ollama pull qwen2.5-coder:7b
docker exec -it ollama ollama pull llama3.1:8b
```

---

## VRAM Management During Gaming Sessions

* **Ollama:** Configured with `OLLAMA_KEEP_ALIVE=5m`. It automatically flushes model weights from VRAM after 5 minutes of idle time.
* **ComfyUI:** Diffusion checkpoints can occupy 8–16 GB of VRAM. Before launching graphics-heavy games:
  ```powershell
  # Free VRAM:
  docker stop comfyui

  # Resume ComfyUI after gaming:
  docker start comfyui
  ```

---

## Testing in a Virtual Machine (No GPU)

The orchestrator includes automatic environment detection:
* When executed in a VM without an NVIDIA GPU, it automatically configures **CPU-fallback mode** so containers pull and start cleanly without `driver: nvidia` runtime errors.
* When run on bare-metal hardware with an NVIDIA GPU, it automatically injects full NVIDIA CUDA reservations.
