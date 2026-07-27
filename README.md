# Ubuntu Docker Environments

Create Ubuntu 26.04 desktop environments with RDP, key-only SSH, persistent storage, optional NVIDIA CUDA, and an isolated Docker-in-Docker engine. New environments can use Cloudflare Zero Trust for remote access without a public IP, domain, or inbound port.

## Requirements

- Docker Engine 28.0.0+ and Docker Compose 2.33.1+
- OpenSSH `ssh-keygen`
- Windows: Docker Desktop with the WSL2 backend
- Ubuntu: rootful Docker, with your user allowed to run `docker`

## Cloudflare setup (once)

1. Create a Cloudflare Zero Trust organization and restrict device enrollment to your account.
2. Set the Cloudflare One Client (WARP) device profile to **Traffic and DNS** mode.
3. Ensure the private pool is routed through WARP. In **Include IPs and domains** mode, add the pool. In **Exclude IPs and domains** mode, split or replace any broader RFC1918 exclusion so that the pool is no longer excluded.
4. Create an account API token limited to one account with:
   - `Cloudflare One Connector: cloudflared` — Write
   - `Cloudflare One Networks` — Write
5. Copy `.env.example` to `.env` and fill in its four values. Do not quote, commit, or share the token.

On Ubuntu, protect the configuration before running the generator:

```bash
chmod 600 .env
```

Choose an RFC1918 pool that does not overlap any LAN, Docker network, corporate VPN, or other Cloudflare private route. The default example is `10.210.0.0/16`.

Install the Cloudflare One Client on each remote device, enroll it in the same Zero Trust organization, and connect WARP. Enable Gateway TCP proxying, then add policies that allow only approved users/devices to reach the assigned environment `/32` on TCP `22` and `3389`. The Docker host must be able to make outbound HTTPS connections; allow outbound port `7844` over UDP and TCP when an egress firewall filters traffic.

## Create an environment

Windows PowerShell:

```powershell
cd D:\DockerVMs
powershell -ExecutionPolicy Bypass -File .\NewUbuntuDindEnvironment.ps1
```

Ubuntu:

```bash
cd /path/to/DockerVMs
chmod +x new_ubuntu_dind_environment.sh
./new_ubuntu_dind_environment.sh
```

Cloudflare is the default for new environments; Ubuntu also offers `cloudflare`/`wireguard` at its prompt. The generator creates one remotely managed tunnel and one unique private `/32` route, then gives the environment only its tunnel-specific runtime token. The account API token remains in the root `.env` and is never copied into a generated environment or container.

Generated connection files:

- `<environment>_local.rdp`: LAN address and published RDP port
- `<environment>_remote.rdp`: Cloudflare private address on port `3389`
- `<environment>_ssh.pem`: private key for both local and remote SSH

Connect WARP before opening the remote RDP file or running the remote SSH command shown in the generated README. Cloudflare Tunnel connects outbound, so no inbound Cloudflare or WireGuard port is required on the Docker host.

## Storage, limits, and GPU

Persistent data is stored under:

```text
mount/<environment>/home
mount/<environment>/workspace
```

Enter `-1` at a CPU or RAM prompt to remove that service's limit. Host and Docker backend limits still apply.

On an Ubuntu NVIDIA host, prepare Docker before enabling GPU support:

```bash
chmod +x setup_nvidia_docker_host.sh
sudo ./setup_nvidia_docker_host.sh
```

Windows WSL2 can expose the GPU to the desktop and DinD services, but nested GPU containers depend on the Docker Desktop/WSL stack.

## Legacy WireGuard mode

The generators retain `wireguard` mode for existing deployments. It requires a separately reachable public WireGuard Hub, its public key and endpoint, and a unique VPN `/32`. Existing generated environments are not migrated or modified automatically.

## Notes

- Host port `3389` is reserved and is never published or changed.
- SSH password login is disabled. The account password is used only for RDP and `sudo`.
- The DinD daemon is privileged and is not a VM-grade security boundary.
- Never commit the root `.env`, generated secrets, PEM keys, or tunnel tokens.
- Do not run `docker compose down -v` unless permanent loss of DinD data and SSH host keys is intended.
- Before deleting a Cloudflare environment, remove its `/32` route and tunnel using the IDs in `.environment.json`.
