# Architecture Design Document: Windows 11 AI & Gaming Workstation

## 1. System Overview
The architecture enables a single physical Windows 11 machine to fulfill three historically conflicting roles simultaneously:
1. An AI compute node serving LLMs (Ollama), chat interfaces (Open WebUI), and diffusion models (ComfyUI).
2. A headless/remote gaming workstation streaming low-latency video via Sunshine to Moonlight clients with virtual controller emulation.
3. A virtualization testbed (Hyper-V) hosting independent VMs bridged to the physical network.

## 2. Hardware Resource Partitioning

```text
+-------------------------------------------------------------------------+
|                          NVIDIA RTX GPU                                 |
+------------------------------+---------------------------+--------------+
| 3D Graphics Engine           | NVENC Video Encoder       | CUDA Cores   |
| (DirectX / Vulkan Games)     | (Sunshine Stream Encoding)| (Ollama /    |
|                              |                           |  ComfyUI)    |
+------------------------------+---------------------------+--------------+
|                       Shared VRAM Pool (12GB - 24GB)                    |
+-------------------------------------------------------------------------+
```

### Contention Management
- **Compute Isolation**: The GPU's NVENC ASIC operates independently of CUDA and 3D graphics cores. Streaming games at 4K 120 FPS incurs zero measurable impact on AI computation.
- **VRAM Contention**: Managed via `OLLAMA_KEEP_ALIVE=5m` (auto-unloading LLMs) and transient container control for ComfyUI (`docker stop comfyui`).

## 3. Network Topology

```text
                             Physical LAN (Router DHCP)
                                         |
               +-------------------------+-------------------------+
               |                                                   |
      Windows 11 Host IP                                    Hyper-V VM IPs
   (Physical NIC & Mirrored WSL2)                     (Bridged via External Switch)
         |              |                                          |
   [AI Containers]  [Sunshine]                                 [Lab VMs]
   - :11434 (Ollama)- :47990 (Web)                             - Independent IPs
   - :3000 (WebUI)  - :47984-48010 (Stream)                    - Direct LAN peers
   - :8188 (ComfyUI)
```

## 4. Software Stack Selection
- **Orchestration**: Native PowerShell (Windows 5.1 / 7+) for zero external dependency bootstrapping.
- **Containerization**: Docker Desktop on WSL2 with Mirrored Networking mode for direct host-adapter binding.
- **Game Streaming**: Sunshine host + ViGEmBus driver for native XInput gamepad emulation.
