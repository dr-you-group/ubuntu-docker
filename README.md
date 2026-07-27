# Ubuntu Docker-in-Docker Environments

These scripts create Ubuntu 26.04 desktop environments with local and WireGuard-based remote RDP/SSH, persistent storage, optional NVIDIA CUDA, and an isolated Docker-in-Docker engine.

## Requirements

- Docker Engine 28.0.0 or newer and Docker Compose 2.33.1 or newer
- OpenSSH `ssh-keygen` for the generated PEM identity
- A public WireGuard Hub with peer forwarding enabled
- The Hub IPv4 endpoint (or a hostname with an IPv4 A record) and public key, plus a unique VPN address for each environment
- Windows: Docker Desktop using the WSL2 backend
- Ubuntu: rootful Docker, with your user allowed to run `docker`

## Windows

Run PowerShell:

```powershell
cd D:\DockerVMs
powershell -ExecutionPolicy Bypass -File .\NewUbuntuDindEnvironment.ps1
```

Follow the prompts for the environment, local network, WireGuard Hub, VPN address, CPU, RAM, and GPU.

## Ubuntu

Make the scripts executable:

```bash
cd /path/to/DockerVMs
chmod +x new_ubuntu_dind_environment.sh setup_nvidia_docker_host.sh
```

If the host has an NVIDIA GPU, prepare the host first:

```bash
sudo ./setup_nvidia_docker_host.sh
```

If a driver was installed, reboot and run the command again. The helper follows Ubuntu's recommended driver flow and configures NVIDIA Container Toolkit for Docker.

Create an environment as your normal user:

```bash
./new_ubuntu_dind_environment.sh
```

GPU detection defaults to `auto`. You can also use `--gpu on` or `--gpu off`.

PowerShell scripts use `UpperCamelCase`; Linux shell scripts use `lower_snake_case`.

## Resource limits

Enter `-1` for any CPU or RAM prompt to remove that service's limit. Docker backend and host limits still apply. Rerun the generator to switch between limited and unlimited; editing `.env` alone does not add or remove Compose resource keys.

## After creation

Each environment is stored in:

```text
<root>/<environment>
<root>/mount/<environment>/home
<root>/mount/<environment>/workspace
```

Each environment contains:

- `<environment>_ssh.pem`: private key for both local and remote SSH
- `<environment>_local.rdp`: LAN connection through the published host port
- `<environment>_remote.rdp`: WireGuard connection to VPN port `3389`
- `wireguard/<environment>_hub_peer.conf`: Hub peer block, created after first startup

Add the generated peer block to the Hub. Connect remote devices to that Hub and allow the environment VPN `/32`. SSH password authentication is disabled; the account password remains available for RDP and `sudo`.

## Important notes

- Host port `3389` is reserved and is never published or modified.
- The environment WireGuard sidecar makes an outbound connection; no WireGuard port is published on the Docker host.
- Assign a unique VPN address and use a WireGuard CIDR that does not overlap LAN, corporate VPN, or Docker networks.
- Assign remote client tunnel addresses from that same WireGuard CIDR so reply traffic returns through the Hub.
- Automatic VPN address selection is unique only within the current root directory. Reserve each `/32` across the entire Hub and all Docker hosts, and remove its Hub peer when deleting an environment.
- Do not run `docker compose down -v`; it deletes DinD data, SSH host keys, and the WireGuard identity.
- The DinD service is privileged. This is isolation for convenient development, not a VM-grade security boundary.
- Treat Docker administrators and host accounts with Modify/Delete access to the selected root as trusted. Use a private root when host users are mutually untrusted.
- Windows WSL2 supports GPU access in the desktop and DinD service, but nested GPU containers may fail. Native Ubuntu creation succeeds only after its nested CUDA check passes.
