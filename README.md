# Ubuntu Docker-in-Docker Environments

Create Ubuntu 26.04 desktop environments with RDP, SSH, Firefox, Korean input, optional resource limits, persistent storage, and an isolated Docker-in-Docker engine.

## Requirements

- Docker Engine and Docker Compose v2
- Windows: Docker Desktop using the WSL2 backend
- Ubuntu: rootful Docker, with your user allowed to run `docker`

## Windows

Run PowerShell:

```powershell
cd D:\DockerVMs
powershell -ExecutionPolicy Bypass -File .\NewUbuntuDindEnvironment.ps1
```

Follow the prompts for the environment name, account, password, network, ports, CPU, RAM, and GPU.

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

Open the generated `.rdp` file for RDP, or use the SSH command printed by the generator.

## Important notes

- Host port `3389` is reserved and is never published or modified.
- Do not run `docker compose down -v`; it deletes DinD data and SSH host-key volumes.
- The DinD service is privileged. This is isolation for convenient development, not a VM-grade security boundary.
- Windows WSL2 supports GPU access in the desktop and DinD service, but nested GPU containers may fail. Native Ubuntu creation succeeds only after its nested CUDA check passes.
