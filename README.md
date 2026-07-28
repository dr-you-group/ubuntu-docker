# Ubuntu Docker Environments

Create Ubuntu 26.04 desktop environments with RDP, key-only SSH, persistent storage, optional NVIDIA CUDA, and an isolated Docker-in-Docker (DinD) engine.

New environments use Cloudflare Zero Trust by default, so they can be reached from a cellular network or another external network without a public IP, domain, router port forwarding, or inbound firewall rule.

## Contents

- [What this project creates](#what-this-project-creates)
- [Requirements](#requirements)
- [Run without host administrator privileges](#run-without-host-administrator-privileges)
- [How Cloudflare remote access works](#how-cloudflare-remote-access-works)
- [Cloudflare Zero Trust setup](#cloudflare-zero-trust-setup-one-time)
- [Create an environment](#create-an-environment)
- [Enroll a remote computer](#enroll-a-remote-computer)
- [Connect locally or remotely](#connect-locally-or-remotely)
- [Verify Cloudflare routing](#verify-cloudflare-routing)
- [Troubleshooting](#troubleshooting-cloudflare-remote-access)
- [Storage, limits, and GPU](#storage-limits-and-gpu)

## What this project creates

Each default Cloudflare environment has its own Ubuntu desktop, Linux account, SSH key, DinD engine, persistent directories, and Cloudflare Tunnel. Legacy WireGuard environments use a WireGuard sidecar instead.

| Connection | Address | Authentication |
| --- | --- | --- |
| Local RDP | Docker host LAN address and selected port `3390` or higher | Linux account password |
| Remote RDP | Cloudflare private IP and internal port `3389` | Linux account password |
| Local SSH | Docker host LAN address and selected host SSH port | Generated PEM key |
| Remote SSH | Cloudflare private IP and port `22` | The same generated PEM key |

Visual Studio Code is installed from [Microsoft's official Linux repository](https://code.visualstudio.com/docs/setup/linux). Launch it from the Xfce application menu or run `code` in the desktop terminal; no separate `.deb` installation is required.

Host port `3389` remains reserved for the Windows server. The generator never publishes, changes, or takes over that port.

## Requirements

- Docker Engine 28.0.0+ and Docker Compose 2.33.1+
- OpenSSH `ssh-keygen`
- A Cloudflare account with a Zero Trust organization
- Windows: Docker Desktop with the WSL2 backend
- Ubuntu: rootful Docker, with your user allowed to run `docker`
- Optional NVIDIA GPU on Ubuntu: a working host driver and NVIDIA Container Toolkit
- Optional NVIDIA GPU on Windows: a compatible Windows NVIDIA driver and Docker Desktop/WSL2 GPU support

## Run without host administrator privileges

Both generators can create and start an environment without running the terminal as Administrator or using host `sudo`, provided that the host prerequisites are already installed and the current account can use Docker and write to the repository and selected output path. Skip the optional host-firewall step with the platform-specific option below.

Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\NewUbuntuDindEnvironment.ps1 -SkipFirewall
```

Ubuntu shell:

```bash
./new_ubuntu_dind_environment.sh --skip-firewall
```

On Ubuntu, you can instead answer `n` when asked whether to apply the LAN-only Docker firewall policy. On Windows, pass `-SkipFirewall` when starting the command to prevent UAC elevation; canceling the later UAC prompt without this switch is treated as a generation failure. `-ExecutionPolicy Bypass` applies only to that PowerShell process and does not grant administrator rights.

These options do not bypass Docker permissions: `docker info` must already succeed for the current account. Installing Docker Desktop or rootful Docker, enabling WSL2, installing Windows OpenSSH Client, granting Docker access, and installing optional GPU drivers or the NVIDIA Container Toolkit can still require an administrator. The Ubuntu generator requires rootful Docker and does not support rootless Docker; access to a rootful Docker daemon is effectively root-equivalent and must be limited to trusted users.

Skipping the firewall step leaves the generated host firewall policy unapplied. Cloudflare remote access uses an outbound Tunnel and does not require an inbound firewall rule, while local SSH/RDP reachability and exposure are controlled by the host's existing firewall and network policy. An administrator can apply the generated firewall script later if host-enforced LAN restrictions are required.

The login password requested by either generator belongs to the generated Ubuntu account. It is used for RDP and for `sudo` inside that container; it is not the Windows administrator password or the Ubuntu host's `sudo` password.

## How Cloudflare remote access works

```text
Remote computer
  -> Cloudflare One Client (WARP)
  -> Cloudflare Zero Trust
  -> outbound cloudflared tunnel
  -> generated Ubuntu environment
```

The generator automatically creates a dedicated remotely managed Tunnel and a unique private `/32` route for every environment. It does **not** configure the account-wide WARP enrollment, device profile, Split Tunnel, or Gateway settings. Complete those one-time settings below before testing remote access.

Cloudflare One Client is installed on each **remote client computer**, not on the Docker host. The generated private address, such as `10.210.0.2`, is not a public Internet address; it works only from an authorized device enrolled in the same Zero Trust organization while WARP is connected.

## Cloudflare Zero Trust setup (one time)

Complete this checklist once for the Cloudflare account:

- [ ] Record the Account ID and Zero Trust team name.
- [ ] Configure a device-enrollment login method and Allow policy.
- [ ] Set the assigned WARP device profile to **Traffic and DNS**.
- [ ] Configure Split Tunnels so the private pool enters WARP.
- [ ] Enable the Gateway TCP proxy.
- [ ] Create a narrowly scoped account API token.
- [ ] Fill in the repository root `.env`.
- [ ] Install and enroll Cloudflare One Client on each remote computer.

### 1. Find the team name and Account ID

Open the [Cloudflare dashboard](https://dash.cloudflare.com/), enter **Zero Trust**, and complete the initial organization setup if necessary.

Find the team domain under:

```text
Zero Trust > Settings > Team name and domain
```

If the domain is `<team-name>.cloudflareaccess.com`, use only `<team-name>` in this project and in Cloudflare One Client. Do not include `.cloudflareaccess.com`.

Copy the Account ID from the Cloudflare account home page. See Cloudflare's [Account and Zone IDs guide](https://developers.cloudflare.com/fundamentals/account/find-account-and-zone-ids/) if the ID is not visible.

### 2. Allow the remote user to enroll

Open:

```text
Zero Trust
  > Team & Resources
  > Devices
  > Device profiles
  > Management
  > Device enrollment permissions
  > Manage
```

Configure both parts before installing the client:

1. Under **Policies**, create an **Allow** policy. For one user, use an Include rule with **Emails** and that user's exact email address. An approved email domain can be used for a group.
2. Under **Login methods**, select the already configured **Cloudflare** login method for Cloudflare account members, another configured identity provider, or **One-time PIN** for approved email addresses.
3. Save the changes.

Without both a matching Allow policy and a login method, the client can report `Enrollment request is invalid`. See [Device enrollment permissions](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/deployment/device-enrollment/).

### 3. Use the Traffic and DNS device mode

First check which profile the remote device actually receives under **Devices** and **Last active device profile**. Then open:

```text
Zero Trust
  > Team & Resources
  > Devices
  > Device profiles
  > General profiles
  > Configure the assigned profile
```

Set **Service mode** to **Traffic and DNS**. `warp-cli settings` normally shows this as `WarpWithDnsOverHttps`.

DNS-only mode cannot carry SSH or RDP traffic. See [Cloudflare One Client modes](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/modes/).

### 4. Configure Split Tunnels safely

This is the most important routing step. WARP's default Exclude configuration normally contains `10.0.0.0/8`, which also excludes this project's default Cloudflare pool, `10.210.0.0/16`. WARP can therefore show **Connected** while SSH and RDP still fail.

Open the profile assigned to the remote device:

```text
Zero Trust
  > Team & Resources
  > Devices
  > Device profiles
  > General profiles
  > Configure
  > Split Tunnels
  > Manage
```

The following procedure is for **Exclude IPs and domains** mode with the default `10.210.0.0/16` pool.

> **Warning:** Do not delete `10.0.0.0/8` first. If the Docker host is on a `10.x` LAN, doing so can immediately send the WARP client's traffic to that host through Cloudflare and disconnect the current RDP session.

1. Keep the existing `10.0.0.0/8` entry in place.
2. Select **Add a destination**, choose **IP Address**, paste one CIDR below, and select **Save destination**. Repeat until all eight IP exclusions have been saved:

   ```text
   10.0.0.0/9
   10.128.0.0/10
   10.192.0.0/12
   10.208.0.0/15
   10.211.0.0/16
   10.212.0.0/14
   10.216.0.0/13
   10.224.0.0/11
   ```

3. Confirm that all eight entries appear in the Exclude list.
4. Only now delete the single broad `10.0.0.0/8` entry.
5. Preserve every other unrelated default Exclude entry.

The final result is:

| Destination | Route used by the remote computer |
| --- | --- |
| `10.210.0.0/16` | Cloudflare WARP |
| Other `10.x` addresses, including a LAN host such as `10.20.30.40` | Normal Wi-Fi or Ethernet route |

These eight entries belong in the **device profile's Split Tunnels Exclude list**. Do not add them under **Networking > Routes**, Windows Firewall, or the Docker environment.

If `CLOUDFLARE_PRIVATE_CIDR` is changed, do not reuse this exact list. Compute the complement for the new pool with the CIDR calculator described in [Split Tunnels](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/).

Include mode is possible, but it also requires the relevant Cloudflare and identity-provider destinations. This beginner guide recommends the Exclude-mode procedure above. See [Split Tunnels](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/) before using Include mode.

### 5. Enable Gateway TCP proxying

Open:

```text
Zero Trust
  > Traffic policies
  > Traffic settings
  > Proxy and inspection
```

Turn on **Allow Secure Web Gateway to proxy traffic**, then enable **TCP**. SSH and RDP require TCP. UDP is not required for IP-address-based SSH/RDP, and ICMP is optional only for diagnostics such as ping.

See [Gateway proxy settings](https://developers.cloudflare.com/cloudflare-one/traffic-policies/proxy/).

### 6. Optionally restrict each environment with policies

Cloudflare allows enrolled devices to reach private routes by default unless another policy blocks them. For production use, create Gateway Network policies in this order:

```text
Zero Trust
  > Traffic policies
  > Firewall policies
  > Network
  > Add a network policy
```

1. A higher-priority **Allow** policy for the approved identity/device, the environment's generated `/32`, TCP, and destination ports `22` and `3389`.
2. A lower-priority **Block** policy for the same environment `/32`, or for the full private pool.

Typical Allow selectors are:

| Selector | Value |
| --- | --- |
| Destination IP | Generated environment address as `/32` |
| Protocol | TCP |
| Destination Port | `22`, `3389` |
| User Email or device posture | The approved user or managed device |

An Allow policy alone does not create a default deny. Policy order matters. See [Gateway Network policies](https://developers.cloudflare.com/cloudflare-one/traffic-policies/network-policies/).

### 7. Create the provisioning API token

Use one of these token types:

- Recommended for an account owner: **Manage Account > Account API Tokens > Create Token**. Account-owned tokens require the appropriate account administrator role.
- Alternative: **My Profile > API Tokens > Create Token > Custom token**. For this user-owned token, set **Account Resources** to the target account.

The exact top-level menu name can vary by dashboard layout. Cloudflare's [API token guide](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/) shows the current entry points.

Grant only these Account permissions:

| Permission | Access |
| --- | --- |
| `Cloudflare One Connector: cloudflared` | Write |
| `Cloudflare One Networks` | Write |

The token must belong to or be scoped to the same account identified by `CLOUDFLARE_ACCOUNT_ID`. A Read-only token can list resources but receives HTTP `403` when the generator creates a Tunnel or route.

This is an API token, not the Cloudflare email address or account password. Copy it when Cloudflare displays it and keep it private.

### 8. Configure the root `.env`

Windows PowerShell:

```powershell
Copy-Item .env.example .env
notepad .env
```

Ubuntu:

```bash
cp .env.example .env
chmod 600 .env
nano .env
```

Fill in all four values:

```dotenv
CLOUDFLARE_API_TOKEN=replace_with_account_api_token
CLOUDFLARE_ACCOUNT_ID=replace_with_32_character_account_id
CLOUDFLARE_TEAM_NAME=replace_with_team_name_only
CLOUDFLARE_PRIVATE_CIDR=10.210.0.0/16
```

Replace every `replace_with_...` value; do not copy it literally. Do not add quotes or spaces around `=`. Choose a canonical RFC1918 pool large enough to contain at least one `/29`, and make sure it does not overlap a LAN, Docker network, corporate VPN, or another Cloudflare private route. Never commit or share `.env`.

The management API token remains only in the repository root `.env`. Each generated environment receives only its Tunnel-specific runtime token.

## Create an environment

Windows PowerShell:

```powershell
cd D:\DockerVMs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\NewUbuntuDindEnvironment.ps1
```

Run the complete command above. `ExecutionPolicy Bypass -File ...` by itself is not a valid PowerShell command.

Ubuntu:

```bash
cd /path/to/DockerVMs
chmod +x new_ubuntu_dind_environment.sh
./new_ubuntu_dind_environment.sh
```

Cloudflare is the default remote-access provider. The Ubuntu generator also offers `cloudflare` or legacy `wireguard` at its provider prompt.

Enter the requested environment name, Linux account name, host address, ports, resource limits, GPU choice, and RDP/sudo password. For CPU or RAM, enter `-1` for no service-level limit. RAM values need a unit, such as `4096m` or `8g`; plain `8` is invalid.

During a normal Cloudflare run, the generator:

1. Allocates an unused `/29` Docker subnet and desktop address from `CLOUDFLARE_PRIVATE_CIDR`.
2. Creates a dedicated remotely managed Tunnel named `dockervm-<environment>`.
3. Creates the environment's private `/32` route.
4. Starts the outbound `cloudflared` connector.
5. Creates the local and remote RDP files and one SSH key.

Do not manually create a second Tunnel or private route for the same environment. Always use the address printed by the generator or recorded in the generated environment's `README.md`; do not assume that it is `10.210.0.2`.

## Enroll a remote computer

Install the [Cloudflare One Client](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/download/) on every computer that will connect from outside the LAN.

### Graphical enrollment

1. Open Cloudflare One Client.
2. Choose **Zero Trust security**.
3. Enter the team name only, without `.cloudflareaccess.com`.
4. Complete browser authentication.
5. On the success page, select **Open the Cloudflare One Client**.
6. Confirm that the client shows **Connected**.

### Command-line enrollment

The graphical flow is simplest for a beginner. If `warp-cli` is available, the equivalent flow is:

```powershell
$TeamName = 'replace-with-your-team-name'
warp-cli registration new $TeamName
warp-cli registration show
warp-cli connect
warp-cli status
warp-cli settings
```

If a previous incorrect registration is cached, delete it once and enroll again:

```powershell
warp-cli registration delete
$TeamName = 'replace-with-your-team-name'
warp-cli registration new $TeamName
```

See [Manual Cloudflare One Client deployment](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/deployment/manual-deployment/).

Profile changes may take up to 10 minutes to reach a device. After waiting, disconnect and reconnect WARP.

## Connect locally or remotely

The generated environment directory contains:

| File | Purpose |
| --- | --- |
| `<environment>_local.rdp` | Local RDP through the Docker host's LAN address and selected published port |
| `<environment>_remote.rdp` | Remote RDP through the environment's Cloudflare private IP and port `3389` |
| `<environment>_ssh.pem` | Private key for both local and remote SSH |
| `README.md` | Exact usernames, addresses, ports, commands, Tunnel ID, and route ID |

Keep the PEM key, generated `secrets/` directory, and Tunnel token private. The RDP files do not contain the login password.

### Local connection

WARP is not required on the LAN. Open `<environment>_local.rdp`, or use the exact local SSH command in the generated README. Its form is:

```powershell
$EnvironmentName = 'replace-with-environment-name'
$LinuxAccount = 'replace-with-linux-account'
$HostLanIp = '10.20.30.40' # Replace with the Docker host's LAN IP.
$HostSshPort = 2223
ssh -o IdentitiesOnly=yes -i ".\$($EnvironmentName)_ssh.pem" -p $HostSshPort "${LinuxAccount}@${HostLanIp}"
```

### Remote connection through Cloudflare

1. Connect the remote computer to the Internet.
2. Confirm that Cloudflare One Client is enrolled in the correct team and WARP is **Connected**.
3. Copy `<environment>_remote.rdp` and `<environment>_ssh.pem` securely to the remote computer.
4. Test the exact private IP shown in the generated README.

On Windows, set `$PrivateIp` to that address:

```powershell
$PrivateIp = '10.210.0.2' # Replace with the generated private IP.
Test-NetConnection $PrivateIp -Port 3389
Test-NetConnection $PrivateIp -Port 22
```

Both commands should show `TcpTestSucceeded : True`.

For RDP, open `<environment>_remote.rdp` and enter the Linux account name and password used during generation.

For remote SSH:

```powershell
$EnvironmentName = 'replace-with-environment-name'
$LinuxAccount = 'replace-with-linux-account'
$PrivateIp = '10.210.0.2' # Replace with the generated private IP.
ssh -o IdentitiesOnly=yes -i ".\$($EnvironmentName)_ssh.pem" "${LinuxAccount}@${PrivateIp}"
```

On macOS or Linux:

```bash
environment_name='replace-with-environment-name'
linux_account='replace-with-linux-account'
private_ip='10.210.0.2' # Replace with the generated private IP.
chmod 600 "${environment_name}_ssh.pem"
ssh -o IdentitiesOnly=yes -i "./${environment_name}_ssh.pem" "${linux_account}@${private_ip}"
```

In VS Code Remote - SSH or another graphical SSH client, split the command into fields. `User` must contain only the Linux account name. Do not put `ssh`, `user@host`, or the entire command in that field:

```sshconfig
Host replace-with-environment-name
    HostName 10.210.0.2
    User replace-with-linux-account
    Port 22
    IdentityFile /absolute/path/to/replace-with-environment-name_ssh.pem
    IdentitiesOnly yes
```

Compare the PEM fingerprint with the exact value in the generated environment README. A key from `.failed`, an older generation, or another environment will not authenticate:

```powershell
ssh-keygen -lf ".\$($EnvironmentName)_ssh.pem"
```

On Windows, the file owner can restrict a copied key without administrator privileges:

```powershell
$KeyPath = (Resolve-Path ".\$($EnvironmentName)_ssh.pem").Path
$CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
icacls.exe $KeyPath /inheritance:r /grant:r "*${CurrentSid}:(R)"
```

Remote SSH uses port `22`; remote RDP uses internal port `3389`. No inbound SSH, RDP, Cloudflare, or WireGuard port needs to be opened on the Docker host. The Tunnel initiates its connection outbound. If an egress firewall filters traffic, allow outbound HTTPS and Cloudflare Tunnel traffic, including TCP and UDP `7844`.

## Verify Cloudflare routing

On the remote Windows computer, set these values from the generated README:

```powershell
$PrivateIp = '10.210.0.2'
$DockerHostLanIp = '10.20.30.40'
$HostSshPort = 2223

warp-cli status
warp-cli registration show
warp-cli settings

$RemoteTest = Test-NetConnection $PrivateIp -Port 3389 -InformationLevel Detailed
$RemoteTest | Select-Object InterfaceAlias, RemoteAddress, RemotePort, TcpTestSucceeded

# Run this LAN comparison only while the client is on the Docker host's LAN.
$LanTest = Test-NetConnection $DockerHostLanIp -Port $HostSshPort -InformationLevel Detailed
$LanTest | Select-Object InterfaceAlias, RemoteAddress, RemotePort, TcpTestSucceeded
```

Expected result:

- The Cloudflare private IP uses a Cloudflare/WARP interface; its exact alias can vary by client version.
- A local `10.x` Docker host still uses `Wi-Fi` or `Ethernet`.
- `warp-cli settings` shows `WarpWithDnsOverHttps` or another traffic-routing mode, not DNS-only mode.

Open [Cloudflare's client status page](https://help.teams.cloudflare.com/) and confirm that WARP and Gateway Proxy are enabled and that the team name is correct.

Do not use `ping` as the main health check. ICMP is optional and may fail even when RDP and SSH work. Use the two TCP tests above instead of ping to verify TCP reachability; successful tests do not by themselves verify SSH authentication or that an XRDP desktop session can start.

## Troubleshooting Cloudflare remote access

### `Permission denied (publickey)`

First copy the exact SSH command from the generated environment README and add `-vvv`. Check these values before changing the server:

- The username is only the generated Linux account name.
- `IdentitiesOnly=yes` is enabled and `IdentityFile` points to the current PEM.
- `ssh-keygen -lf <pem>` matches the fingerprint in the generated README.
- The copied PEM is restricted with the Windows `icacls` or macOS/Linux `chmod 600` command above.

If the server log says `Invalid user ssh <account>`, the client sent `ssh <account>` as the username. This fails before the public key is examined. Correct the VS Code/GUI `User` field; do not rotate the key, enable password login, disable `StrictModes`, or loosen `AllowUsers`.

### `Enrollment request is invalid`

Check that:

- The team name is the slug only, without `.cloudflareaccess.com`.
- The enrollment Allow policy matches the login email.
- A login method is selected.
- The settings were saved in the correct Zero Trust account.

Then remove only the bad client registration and enroll again:

```powershell
warp-cli registration delete
$TeamName = 'replace-with-your-team-name'
warp-cli registration new $TeamName
warp-cli connect
```

### WARP is connected, but both TCP tests fail

Check in this order:

1. `warp-cli settings` shows a traffic-routing mode.
2. The remote device received the device profile that was edited.
3. Gateway proxying and TCP are enabled.
4. `10.210.0.0/16` is not excluded by Split Tunnels.
5. The broad `10.0.0.0/8` exclusion was replaced by all eight narrower entries.
6. A Gateway Block policy is not above the intended Allow policy.
7. **Networking > Tunnels** shows the environment Tunnel as healthy.
8. **Networking > Routes** maps the generated `/32` to that Tunnel.

After a profile change, wait up to 10 minutes and reconnect:

```powershell
warp-cli disconnect
warp-cli connect
```

In **Insights > Logs > Network logs**, filter for the private IP and port:

- No log can mean the client profile, Split Tunnel, or proxy setting is not applied, or that Gateway could not establish the upstream TCP connection.
- A Block result means the Gateway policy must be corrected.
- An Allow result followed by a timeout points to the Tunnel, route, or environment service.

See [Troubleshoot private networks](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/private-networks/).

### LAN RDP stopped after changing Split Tunnels

Disconnect WARP temporarily, restore `10.0.0.0/8` to the Exclude list, then add all eight replacement CIDRs before deleting the broad entry again.

```powershell
warp-cli disconnect
```

This failure occurs when the WARP client routes traffic for all `10.x` destinations through Cloudflare before the other LAN ranges are preserved.

### Ping fails, but TCP succeeds

This is expected when ICMP proxying is not enabled. SSH and RDP use TCP; no action is required if both `Test-NetConnection` commands succeed.

### The Cloudflare Tunnel is not healthy

From the generated environment directory on the Docker host:

```powershell
docker compose ps
docker compose logs --no-color --tail 100 cloudflared
```

Also confirm the Tunnel and `/32` route in **Networking > Tunnels** and **Networking > Routes**.

### Environment creation fails with HTTP `403`

Confirm that both token permissions are **Write**, Account Resources includes the account in `CLOUDFLARE_ACCOUNT_ID`, and `.env` contains the current token without quotes.

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

The generators retain `wireguard` mode for existing deployments. It requires a separately reachable public WireGuard Hub, its public key and endpoint, and a unique VPN `/32`. Existing environments are not migrated or modified automatically.

## Security and maintenance notes

- SSH password login is disabled. The prompted account password is used for RDP and `sudo`.
- The DinD daemon is privileged and is not a VM-grade security boundary.
- Docker blocks the nested namespaces required by Electron's sandbox, so the image's VS Code-only launcher adds `--no-sandbox`. Open only trusted workspaces and extensions; the Compose service does not relax Docker's container-wide seccomp or AppArmor settings.
- Never commit the root `.env`, generated secrets, PEM keys, RDP files, or Tunnel tokens.
- Do not run `docker compose down -v` unless permanent loss of DinD data and SSH host keys is intended.
- Before permanently deleting a Cloudflare environment, remove its private `/32` route and then its Tunnel using the IDs in `.environment.json`.
- The root `.gitignore` hides generated environment directories and sensitive connection files; it is not a substitute for filesystem permissions or secure key transfer.

## Cloudflare references

- [First-time Cloudflare One Client setup](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/set-up/)
- [Device enrollment](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/deployment/device-enrollment/)
- [Split Tunnels](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/)
- [Connect a private IP/CIDR](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/private-net/cloudflared/connect-cidr/)
- [Gateway proxy settings](https://developers.cloudflare.com/cloudflare-one/traffic-policies/proxy/)
- [Private-network troubleshooting](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/private-networks/)
