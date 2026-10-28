# Software Requirements Specification (SRS)

## 1. Functional Requirements
- **FR-1**: Automate the enabling of Windows features: `Microsoft-Hyper-V-All`, `VirtualMachinePlatform`, and `Microsoft-Windows-Subsystem-Linux`.
- **FR-2**: Provide reboot detection and safe resumption without duplicate operations.
- **FR-3**: Bind containerized AI ports (`11434`, `3000`, `8188`) to the host network interface without complex NAT port forwarding.
- **FR-4**: Create an external Hyper-V virtual switch bound to the active physical network card.
- **FR-5**: Install Docker Desktop, Sunshine, and ViGEmBus via silent, automated package management (`winget`).
- **FR-6**: Support automated hardware detection to allow test validation in virtual machines without an NVIDIA GPU.

## 2. Non-Functional Requirements
- **NFR-1 (Idempotence)**: Script can be executed multiple times without corrupting system state or failing.
- **NFR-2 (Zero-Touch Bootstrapping)**: Operable via a single-line command (`irm ... | iex`) without requiring pre-installed Git or SSH.
- **NFR-3 (VRAM Efficiency)**: Automatic unloading of idle LLMs within 5 minutes to prevent out-of-memory errors during gaming sessions.
