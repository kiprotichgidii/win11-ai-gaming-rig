# LEARNINGS.gemini.md

## Log Entry: 2026-10-28 - Windows 11 AI Stack & Gaming Rig Automation

### Perceive
- **Challenge**: The client wants a single Windows 11 workstation running an AI stack (Ollama, Open WebUI, ComfyUI) inside Docker accessible on the host's LAN IP, a Type-2 hypervisor (Hyper-V) bridged to the physical network for VMs, and low-latency remote PC game streaming to a remote client (e.g. Mac/laptop).
- **Constraints**:
  - The engineer cannot SSH into the target Windows host; code must be committed to GitHub and fetched on the Windows machine.
  - The script must be testable inside a Windows VM lacking an NVIDIA GPU prior to client deployment.
  - VRAM contention between AAA gaming and local AI inference must be handled gracefully.

### Reason
- WSL2 historically used NAT mode which caused port forwarding headaches from LAN clients. By using WSL2 `networkingMode=mirrored`, Docker containers bind seamlessly to the Windows host's physical network adapter.
- NVIDIA GPUs contain distinct silicon for graphics (DirectX/Vulkan), video encoding (NVENC), and tensor compute (CUDA). Sunshine uses NVENC, while Ollama/ComfyUI use CUDA, preventing compute contention.
- VRAM is a shared pool; configuring `OLLAMA_KEEP_ALIVE=5m` allows Ollama to evict models during idle periods, freeing memory for gaming.
- Testing on a VM without an NVIDIA GPU causes `docker compose` to fail if `driver: nvidia` is statically declared. The orchestrator must dynamically detect the GPU and generate a CPU-compatible compose file when running in a test VM.

### Act
- Authored `Setup-Rig.ps1` with environment auto-detection (bare-metal vs VM, GPU vs CPU).
- Implemented automated Windows Optional Features activation with reboot detection.
- Configured WSL2 mirrored networking in `%USERPROFILE%\.wslconfig`.
- Automated Hyper-V External Bridged Switch creation across physical and virtual adapters.
- Configured inbound firewall rules for AI ports (`11434`, `3000`, `8188`) and Sunshine streaming ports (`47984-48010`).
- Automated installation of Docker Desktop, Sunshine, and ViGEmBus driver.

### Refine
- Tested VM adapter edge cases where hypervisor virtual adapters were prematurely filtered.
- Provided fallback logic for one-liner execution via `irm <url> | iex` for machines without Git pre-installed.
- **Winget MSStore Bug Fix**: Resolved `Failed when searching source: msstore` common in VM / unauthenticated Windows instances by appending `--source winget` and implementing an automated direct CDN fallback download for `Docker Desktop Installer.exe`.
