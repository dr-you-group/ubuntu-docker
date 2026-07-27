#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

toolkit_version="${NVIDIA_CONTAINER_TOOLKIT_VERSION:-1.19.1-1}"
assume_yes=0
skip_driver=0

usage() {
    cat <<'EOF'
Usage: ./setup_nvidia_docker_host.sh [--yes] [--skip-driver] [--toolkit-version VERSION]

Installs the Ubuntu host NVIDIA compute driver when needed, then installs and
configures NVIDIA Container Toolkit for rootful Docker. A newly installed
kernel driver requires a reboot; rerun this script after reboot.
EOF
}

while (($#)); do
    case "$1" in
        --yes) assume_yes=1 ;;
        --skip-driver) skip_driver=1 ;;
        --toolkit-version)
            shift
            [[ $# -gt 0 ]] || { printf 'ERROR: --toolkit-version requires a value\n' >&2; exit 2; }
            toolkit_version="$1"
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'ERROR: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ "${toolkit_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]] || {
    printf 'ERROR: invalid NVIDIA Container Toolkit version: %s\n' "${toolkit_version}" >&2
    exit 2
}

[[ "$(uname -s)" == Linux ]] || {
    printf 'ERROR: this helper supports Ubuntu Linux only.\n' >&2
    exit 1
}

if grep -Eqi '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null || [[ -n "${WSL_INTEROP:-}" ]]; then
    printf '%s\n' \
        'ERROR: WSL was detected. Do not install a Linux NVIDIA kernel driver in WSL.' \
        'Install/update the NVIDIA Windows host driver and use Docker Desktop with the WSL2 backend instead.' >&2
    exit 1
fi

[[ -r /etc/os-release ]] || { printf 'ERROR: /etc/os-release is missing.\n' >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || {
    printf 'ERROR: unsupported distribution: %s\n' "${PRETTY_NAME:-unknown}" >&2
    exit 1
}
case "${VERSION_ID:-}" in
    22.04|24.04|26.04) ;;
    *)
        printf 'ERROR: Ubuntu %s is not in this helper\x27s tested support list (22.04/24.04/26.04).\n' "${VERSION_ID:-unknown}" >&2
        exit 1
        ;;
esac

command -v sudo >/dev/null 2>&1 || {
    [[ ${EUID} -eq 0 ]] || { printf 'ERROR: sudo is required.\n' >&2; exit 1; }
}

as_root() {
    if [[ ${EUID} -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

confirm() {
    local prompt="$1"
    if ((assume_yes)); then
        return 0
    fi
    local answer
    read -r -p "${prompt} [y/N] " answer
    [[ "${answer}" =~ ^[Yy]$ ]]
}

command -v docker >/dev/null 2>&1 || {
    printf 'ERROR: Docker Engine is not installed. Install Docker first.\n' >&2
    exit 1
}

if docker info >/dev/null 2>&1; then
    docker_command=(docker)
elif as_root docker info >/dev/null 2>&1; then
    docker_command=(as_root docker)
else
    printf 'ERROR: Docker daemon is not reachable.\n' >&2
    exit 1
fi

if "${docker_command[@]}" info --format '{{json .SecurityOptions}}' | grep -q 'rootless'; then
    printf 'ERROR: this helper configures rootful Docker only. Follow NVIDIA\x27s rootless instructions instead.\n' >&2
    exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
    if ((skip_driver)); then
        printf 'ERROR: the NVIDIA host driver is not working and --skip-driver was specified.\n' >&2
        exit 1
    fi
    if ! grep -q '^0x10de$' /sys/bus/pci/devices/*/vendor 2>/dev/null; then
        printf 'ERROR: no NVIDIA PCI device was detected; refusing to install a kernel driver.\n' >&2
        exit 1
    fi
    printf 'The NVIDIA kernel driver is not active. Ubuntu will select a signed compute driver.\n'
    confirm 'Install the recommended NVIDIA compute driver now? A reboot will be required.' || exit 1
    as_root apt-get update
    as_root apt-get install -y ubuntu-drivers-common
    driver_candidates="$(ubuntu-drivers list --gpgpu || true)"
    if [[ -z "${driver_candidates}" ]]; then
        printf 'ERROR: Ubuntu did not report a compatible NVIDIA compute-driver candidate.\n' >&2
        exit 1
    fi
    printf '%s\n' "${driver_candidates}"
    as_root ubuntu-drivers install --gpgpu
    printf '\nNVIDIA driver installation finished. Reboot the host, verify nvidia-smi, then rerun this script.\n'
    exit 20
fi

printf '%s\n' 'Detected host GPU:'
nvidia-smi -L

confirm 'Install/configure NVIDIA Container Toolkit and restart Docker? Running containers will be interrupted.' || exit 1

temporary_directory="$(mktemp -d)"
daemon_config='/etc/docker/daemon.json'
daemon_backup="${temporary_directory}/daemon.json.before-nvidia"
daemon_config_existed=0
runtime_config_changed=0

if as_root test -f "${daemon_config}"; then
    as_root cp --preserve=mode,ownership,timestamps -- "${daemon_config}" "${daemon_backup}"
    daemon_config_existed=1
fi

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    if ((runtime_config_changed)); then
        if ((daemon_config_existed)); then
            as_root cp --preserve=mode,ownership,timestamps -- "${daemon_backup}" "${daemon_config}"
        else
            as_root rm -f -- "${daemon_config}"
        fi
        as_root systemctl restart docker >/dev/null 2>&1 || true
        printf 'WARNING: NVIDIA runtime verification failed; the previous Docker daemon configuration was restored.\n' >&2
    fi
    rm -rf -- "${temporary_directory}"
    exit "${status}"
}
trap cleanup EXIT

as_root apt-get update
as_root apt-get install -y --no-install-recommends ca-certificates curl gnupg2

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    -o "${temporary_directory}/nvidia-container-toolkit.gpg"
gpg --batch --yes --dearmor \
    --output "${temporary_directory}/nvidia-container-toolkit-keyring.gpg" \
    "${temporary_directory}/nvidia-container-toolkit.gpg"
as_root install -m 0644 \
    "${temporary_directory}/nvidia-container-toolkit-keyring.gpg" \
    /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    -o "${temporary_directory}/nvidia-container-toolkit.list"
sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    "${temporary_directory}/nvidia-container-toolkit.list" \
    > "${temporary_directory}/nvidia-container-toolkit-signed.list"
as_root install -m 0644 \
    "${temporary_directory}/nvidia-container-toolkit-signed.list" \
    /etc/apt/sources.list.d/nvidia-container-toolkit.list

as_root apt-get update
as_root apt-get install -y \
    "nvidia-container-toolkit=${toolkit_version}" \
    "nvidia-container-toolkit-base=${toolkit_version}" \
    "libnvidia-container-tools=${toolkit_version}" \
    "libnvidia-container1=${toolkit_version}"

runtime_config_changed=1
as_root nvidia-ctk runtime configure --runtime=docker
as_root systemctl restart docker

for _ in {1..30}; do
    if "${docker_command[@]}" info >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
"${docker_command[@]}" info >/dev/null
"${docker_command[@]}" run --rm --gpus all ubuntu:26.04 nvidia-smi -L
runtime_config_changed=0

printf '\nNVIDIA host driver and Docker GPU runtime are ready.\n'
