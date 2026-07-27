#!/usr/bin/env bash
set -Eeuo pipefail

IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="$(basename -- "$0")"
readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

ENVIRONMENT_NAME=''
ENVIRONMENT_NAME_SNAKE=''
ACCOUNT_NAME=''
PASSWORD_VALUE=''
PASSWORD_SOURCE='prompt'
PASSWORD_FILE=''
HOST_ADDRESS=''
REMOTE_SUBNET=''
SSH_PORT='0'
RDP_PORT='0'
WIREGUARD_HUB_ENDPOINT=''
WIREGUARD_HUB_PUBLIC_KEY=''
WIREGUARD_ADDRESS=''
WIREGUARD_IP=''
WIREGUARD_NETWORK=''
WIREGUARD_MTU=''
WIREGUARD_KEEPALIVE=''
DESKTOP_CPUS=''
DESKTOP_MEMORY=''
DIND_CPUS=''
DIND_MEMORY=''
ACCOUNT_UID=''
ACCOUNT_GID=''
DOCKER_VERSION=''
ROOT_PATH="${SCRIPT_DIRECTORY}"
GPU_MODE='auto'
GPU_ENABLED='0'
CUDA_IMAGE='nvidia/cuda:12.2.2-base-ubuntu22.04'
NVIDIA_CONTAINER_TOOLKIT_VERSION='1.19.1-1'
CUDA_IMAGE_EXPLICIT='0'
NVIDIA_TOOLKIT_VERSION_EXPLICIT='0'
REPLACE='0'
MIGRATE_LEGACY_HOME='auto'
ALLOW_DOCKER_VERSION_CHANGE='0'
USE_BUILDKIT='0'
GENERATE_ONLY='0'
FIREWALL_MODE='ask'
ROTATE_SSH_KEY='0'
SSH_KEY_FINGERPRINT=''
SSH_PRIVATE_KEY_FILE=''
SSH_PUBLIC_KEY_FILE=''
DOCKER_COMPOSE_VERSION=''
DOCKER_COMPOSE_VERSION_ERROR=''
DOCKER_ENGINE_VERSION=''
DOCKER_ENGINE_VERSION_ERROR=''

TARGET_PATH=''
STAGING_PATH=''
STORAGE_PATH=''
HOME_STORAGE_PATH=''
WORKSPACE_STORAGE_PATH=''
BACKUP_PATH=''
TEMPLATE_PATH=''
OLD_TARGET_EXISTED='0'
OLD_STOPPED='0'
SWAPPED='0'
NEW_STARTED='0'
COMPLETED='0'
FIREWALL_APPLIED='0'
FIREWALL_ATTEMPTED='0'
LAST_FAILED_COMMAND=''

declare -A ALLOWED_EXISTING_PORTS=()
declare -A TEMPLATE_TOKENS=()

usage() {
    cat <<'EOF'
Create an Ubuntu Xfce/RDP/SSH environment with an isolated Docker-in-Docker engine.

Usage:
  new_ubuntu_dind_environment.sh [options]

Requirements:
  Docker Engine 28.0.0 or newer and Docker Compose 2.33.1 or newer.

Identity and storage:
  --environment, --environment-name NAME
  --account, --account-name NAME
  --password VALUE              Insecure on shared systems; prefer a file/stdin.
  --password-file PATH          Read the password from a mode-600 file.
  --password-stdin              Read one password line from standard input.
  --uid UID                     Container account UID (default: current UID or 1001).
  --gid GID                     Container account GID (default: current GID or 1001).
  --root PATH                   Output/storage root (default: script directory).
                                Templates are always read beside this script.

Network and resources:
  --host-address IPv4
  --remote-subnet CIDR
  --ssh-port PORT
  --rdp-port PORT               Must be 3390 or higher; host 3389 is reserved.
  --wireguard-hub-endpoint HOST:PORT
                                Public Hub IPv4 literal or DNS hostname and port.
  --wireguard-hub-public-key KEY
                                Base64 WireGuard Hub public key.
  --wireguard-address IPv4/CIDR
                                Usable host address with a /8 through /29 prefix.
                                Default: first unused /24 IP from 10.200.0.10.
  --wireguard-mtu MTU           1280-1420 (default: 1380).
  --wireguard-keepalive SECONDS 0-65535 (default: 25).
  --desktop-cpus NUMBER|-1      Use -1 for unlimited.
  --desktop-memory SIZE|-1      Example: 4g or 4096m; use -1 for unlimited.
  --dind-cpus NUMBER|-1         Use -1 for unlimited.
  --dind-memory SIZE|-1         Example: 8g or 8192m; use -1 for unlimited.

Docker and GPU:
  --docker-version X.Y.Z
  --gpu auto|on|off             auto enables only after host/runtime probes pass.
  --cuda-image IMAGE
  --nvidia-toolkit-version VER
  --use-buildkit

Lifecycle:
  --replace
  --migrate-legacy-home
  --no-migrate-legacy-home
  --allow-docker-version-change
  --rotate-ssh-key              Replace the environment's existing SSH client key.
  --generate-only
  --apply-firewall
  --skip-firewall
  -h, --help
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

info() {
    printf '%s\n' "$*"
}

require_option_value() {
    local option="$1"
    local count="$2"
    (( count >= 2 )) || die "Missing value for ${option}."
}

is_interactive() {
    [[ -t 0 && -t 1 ]]
}

read_with_default() {
    local destination="$1"
    local prompt="$2"
    local default_value="$3"
    local value=''

    if ! is_interactive; then
        printf -v "${destination}" '%s' "${default_value}"
        return 0
    fi
    read -r -p "${prompt} [${default_value}]: " value
    [[ -n "${value}" ]] || value="${default_value}"
    printf -v "${destination}" '%s' "${value}"
}

read_required_with_default() {
    local destination="$1"
    local prompt="$2"
    local default_value="$3"
    local option_name="$4"
    local value=''

    if ! is_interactive; then
        [[ -n "${default_value}" ]] ||
            die "${option_name} is required in non-interactive mode and no existing environment default is available."
        printf -v "${destination}" '%s' "${default_value}"
        return 0
    fi
    if [[ -n "${default_value}" ]]; then
        read_with_default "${destination}" "${prompt}" "${default_value}"
    else
        read -r -p "${prompt}: " value
        [[ -n "${value}" ]] || die "${prompt} must not be empty."
        printf -v "${destination}" '%s' "${value}"
    fi
}

read_yes_no() {
    local prompt="$1"
    local default_value="$2"
    local answer=''

    is_interactive || return 2
    read -r -p "${prompt} [${default_value}]: " answer
    [[ -n "${answer}" ]] || answer="${default_value}"
    [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

validate_no_line_breaks() {
    local label="$1"
    local value="$2"
    [[ ! "${value}" =~ [[:cntrl:]] ]] ||
        die "${label} must not contain control characters."
}

validate_ipv4() {
    local address="$1"
    local first second third fourth octet numeric
    [[ "${address}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    first="${BASH_REMATCH[1]}"
    second="${BASH_REMATCH[2]}"
    third="${BASH_REMATCH[3]}"
    fourth="${BASH_REMATCH[4]}"
    for octet in "${first}" "${second}" "${third}" "${fourth}"; do
        numeric=$((10#${octet}))
        (( numeric <= 255 )) || return 1
    done
    [[ "${address}" != '0.0.0.0' ]]
}

validate_host_ipv4() {
    local address="$1"
    local first second _
    validate_ipv4 "${address}" || return 1
    IFS='.' read -r first second _ <<<"${address}"
    first=$((10#${first}))
    second=$((10#${second}))
    (( first != 127 && first < 224 )) || return 1
    (( first != 169 || second != 254 ))
}

validate_cidr() {
    local value="$1"
    local address prefix
    [[ "${value}" == */* ]] || return 1
    address="${value%/*}"
    prefix="${value##*/}"
    validate_ipv4 "${address}" || return 1
    [[ "${prefix}" =~ ^[0-9]{1,2}$ ]] || return 1
    prefix=$((10#${prefix}))
    (( prefix >= 8 && prefix <= 32 ))
}

validate_hostname() {
    local value="${1%.}"
    local label
    local -a labels=()

    [[ -n "${value}" && ${#value} -le 253 ]] || return 1
    [[ "${value}" != *..* ]] || return 1
    IFS='.' read -r -a labels <<<"${value}"
    (( ${#labels[@]} > 0 )) || return 1
    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
        [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

validate_wireguard_endpoint() {
    local value="$1"
    local host port

    if [[ "${value}" =~ ^([^][]+):([0-9]{1,5})$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        [[ "${host}" != *:* ]] || return 1
        if [[ "${host}" =~ ^[0-9.]+$ ]]; then
            validate_ipv4 "${host}" || return 1
        else
            validate_hostname "${host}" || return 1
        fi
    else
        return 1
    fi
    validate_port_number "${port}"
}

validate_wireguard_public_key() {
    local value="$1"
    local byte_count

    [[ "${value}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
    [[ "${value}" != 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' ]] || return 1
    byte_count="$(printf '%s' "${value}" | base64 --decode 2>/dev/null | wc -c)" || return 1
    byte_count="${byte_count//[[:space:]]/}"
    [[ "${byte_count}" == 32 ]]
}

validate_wireguard_address() {
    local value="$1"
    local address prefix address_integer mask network broadcast

    [[ "${value}" == */* && "${value}" != */*/* ]] || return 1
    address="${value%/*}"
    prefix="${value##*/}"
    validate_host_ipv4 "${address}" || return 1
    [[ "${prefix}" =~ ^[0-9]{1,2}$ ]] || return 1
    prefix=$((10#${prefix}))
    (( prefix >= 8 && prefix <= 29 )) || return 1
    address_integer="$(ipv4_to_integer "${address}")"
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    network=$(( address_integer & mask ))
    broadcast=$(( network | ((~mask) & 0xFFFFFFFF) ))
    (( address_integer != network && address_integer != broadcast ))
}

canonicalize_wireguard_address() {
    local value="$1"
    local address prefix a b c d

    validate_wireguard_address "${value}" || return 1
    address="${value%/*}"
    prefix="${value##*/}"
    IFS='.' read -r a b c d <<<"${address}"
    printf '%d.%d.%d.%d/%d\n' \
        "$((10#${a}))" "$((10#${b}))" "$((10#${c}))" "$((10#${d}))" "$((10#${prefix}))"
}

cidr_ranges_overlap() {
    local first="$1"
    local second="$2"
    local first_address first_prefix second_address second_prefix
    local first_mask second_mask first_start first_end second_start second_end

    first_address="${first%/*}"
    first_prefix=$((10#${first##*/}))
    second_address="${second%/*}"
    second_prefix=$((10#${second##*/}))
    first_mask=$(( (0xFFFFFFFF << (32 - first_prefix)) & 0xFFFFFFFF ))
    second_mask=$(( (0xFFFFFFFF << (32 - second_prefix)) & 0xFFFFFFFF ))
    first_start=$(( $(ipv4_to_integer "${first_address}") & first_mask ))
    second_start=$(( $(ipv4_to_integer "${second_address}") & second_mask ))
    first_end=$(( first_start | ((~first_mask) & 0xFFFFFFFF) ))
    second_end=$(( second_start | ((~second_mask) & 0xFFFFFFFF) ))
    (( first_start <= second_end && second_start <= first_end ))
}

ipv4_to_integer() {
    local address="$1"
    local a b c d
    IFS='.' read -r a b c d <<<"${address}"
    printf '%u\n' "$(( (10#${a} << 24) | (10#${b} << 16) | (10#${c} << 8) | 10#${d} ))"
}

integer_to_ipv4() {
    local value="$1"
    printf '%d.%d.%d.%d\n' \
        "$(( (value >> 24) & 255 ))" \
        "$(( (value >> 16) & 255 ))" \
        "$(( (value >> 8) & 255 ))" \
        "$(( value & 255 ))"
}

network_cidr() {
    local address="$1"
    local prefix="$2"
    local address_integer mask network
    address_integer="$(ipv4_to_integer "${address}")"
    if (( prefix == 32 )); then
        mask=$((0xFFFFFFFF))
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    network=$(( address_integer & mask ))
    printf '%s/%s\n' "$(integer_to_ipv4 "${network}")" "${prefix}"
}

detect_lan_defaults() {
    local route interface source address_prefix prefix
    route="$(ip -4 route show default 2>/dev/null | awk 'NR == 1 { print; exit }')"
    interface="$(awk '{ for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }' <<<"${route}")"
    source="$(awk '{ for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit } }' <<<"${route}")"

    if [[ -z "${interface}" ]]; then
        interface="$(ip -o -4 addr show scope global 2>/dev/null | awk 'NR == 1 { print $2; exit }')"
    fi
    [[ -n "${interface}" ]] || die 'Unable to detect a LAN interface. Specify --host-address and ensure iproute2 is installed.'

    address_prefix="$(ip -o -4 addr show dev "${interface}" scope global 2>/dev/null |
        awk -v wanted="${source}" '$4 ~ wanted || wanted == "" { print $4; exit }')"
    [[ -n "${address_prefix}" ]] ||
        address_prefix="$(ip -o -4 addr show dev "${interface}" 2>/dev/null | awk 'NR == 1 { print $4; exit }')"
    [[ -n "${address_prefix}" ]] || die "Unable to find an IPv4 address on ${interface}."

    DETECTED_HOST_ADDRESS="${address_prefix%/*}"
    prefix="${address_prefix##*/}"
    DETECTED_REMOTE_SUBNET="$(network_cidr "${DETECTED_HOST_ADDRESS}" "${prefix}")"
}

host_has_address() {
    local wanted="$1"
    ip -o -4 addr show 2>/dev/null |
        awk '{ split($4, parts, "/"); print parts[1] }' |
        grep -Fqx -- "${wanted}"
}

read_environment_value() {
    local file="$1"
    local key="$2"
    [[ -f "${file}" ]] || return 1
    awk -F= -v key="${key}" '
        $1 == key {
            value = substr($0, index($0, "=") + 1)
            if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
                value = substr(value, 2, length(value) - 2)
            }
            print value
            exit
        }
    ' "${file}"
}

wireguard_ip_in_use() {
    local wanted_ip="$1"
    local environment_file address

    while IFS= read -r -d '' environment_file; do
        [[ "${environment_file}" != "${TARGET_PATH}/.env" ]] || continue
        address="$(read_environment_value "${environment_file}" WIREGUARD_ADDRESS || true)"
        validate_wireguard_address "${address}" || continue
        address="$(canonicalize_wireguard_address "${address}")" || continue
        [[ "${address%/*}" != "${wanted_ip}" ]] || return 0
    done < <(find "${ROOT_PATH}" -mindepth 2 -maxdepth 2 -type f -name .env -print0 2>/dev/null)
    return 1
}

select_default_wireguard_address() {
    local final_octet candidate_ip

    for ((final_octet = 10; final_octet <= 254; final_octet += 1)); do
        candidate_ip="10.200.0.${final_octet}"
        if ! wireguard_ip_in_use "${candidate_ip}"; then
            printf '%s/24\n' "${candidate_ip}"
            return 0
        fi
    done
    return 1
}

remember_allowed_port() {
    local port="${1:-}"
    [[ "${port}" =~ ^[0-9]+$ ]] || return 0
    ALLOWED_EXISTING_PORTS["$((10#${port}))"]='1'
}

collect_existing_environment_ports() {
    local env_file="$1"
    local value project id output port legacy_id
    for value in SSH_PORT RDP_PORT; do
        port="$(read_environment_value "${env_file}" "${value}" || true)"
        remember_allowed_port "${port}"
    done

    for project in "${ENVIRONMENT_NAME}" "ubuntu-dind-${ENVIRONMENT_NAME}"; do
        while IFS= read -r id; do
            [[ -n "${id}" ]] || continue
            output="$(docker inspect --format '{{range $key, $items := .HostConfig.PortBindings}}{{range $items}}{{println .HostPort}}{{end}}{{end}}' "${id}" 2>/dev/null || true)"
            while IFS= read -r port; do
                remember_allowed_port "${port}"
            done <<<"${output}"
        done < <(docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true)
    done

    legacy_id="$(docker inspect --format '{{.Id}}' "${ENVIRONMENT_NAME}" 2>/dev/null || true)"
    if [[ -n "${legacy_id}" ]]; then
        output="$(docker inspect --format '{{range $key, $items := .HostConfig.PortBindings}}{{range $items}}{{println .HostPort}}{{end}}{{end}}' "${legacy_id}" 2>/dev/null || true)"
        while IFS= read -r port; do
            remember_allowed_port "${port}"
        done <<<"${output}"
    fi
}

port_is_listening() {
    local port="$1"
    [[ -n "$(ss -H -ltn "sport = :${port}" 2>/dev/null)" ]]
}

find_free_port() {
    local candidate="$1"
    while (( candidate <= 65535 )); do
        if (( candidate != 3389 )) &&
            { ! port_is_listening "${candidate}" || [[ -n "${ALLOWED_EXISTING_PORTS[${candidate}]:-}" ]]; }; then
            printf '%d\n' "${candidate}"
            return 0
        fi
        ((candidate += 1))
    done
    return 1
}

validate_port_number() {
    local value="$1"
    [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
    value=$((10#${value}))
    (( value >= 1 && value <= 65535 ))
}

validate_cpu_value() {
    local value="$1"
    [[ "${value}" == -1 ]] && return 0
    # Requiring an integer part also keeps the value valid when written as a
    # JSON number in .environment.json (for example, use 0.5 rather than .5).
    [[ "${value}" =~ ^(0|[1-9][0-9]*)([.][0-9]+)?$ ]] || return 1
    awk -v value="${value}" 'BEGIN { exit !(value >= 0.25) }'
}

normalise_memory_value() {
    local value="${1,,}"
    if [[ "${value}" == -1 ]]; then
        printf '%s\n' "${value}"
        return 0
    fi
    [[ "${value}" =~ ^[1-9][0-9]*([.][0-9]+)?[mg]$ ]] || return 1
    printf '%s\n' "${value}"
}

resource_display_value() {
    local value="$1"
    if [[ "${value}" == -1 ]]; then
        printf 'unlimited (-1)'
    else
        printf '%s' "${value}"
    fi
}

memory_bytes() {
    local value="${1,,}"
    awk -v value="${value}" 'BEGIN {
        unit = substr(value, length(value), 1)
        amount = substr(value, 1, length(value) - 1) + 0
        multiplier = (unit == "g" ? 1073741824 : 1048576)
        printf "%.0f\n", amount * multiplier
    }'
}

detect_docker_resources() {
    local raw
    raw="$(docker info --format '{{.NCPU}}|{{.MemTotal}}' 2>/dev/null || true)"
    BACKEND_CPUS="${raw%%|*}"
    BACKEND_MEMORY_BYTES="${raw#*|}"
    if [[ "${raw}" != *'|'* || ! "${BACKEND_CPUS}" =~ ^[0-9]+$ || ! "${BACKEND_MEMORY_BYTES}" =~ ^[0-9]+$ ]] ||
        (( BACKEND_CPUS < 1 || BACKEND_MEMORY_BYTES < 1 )); then
        BACKEND_CPUS="$(nproc)"
        BACKEND_MEMORY_BYTES="$(( $(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo) * 1024 ))"
    fi
}

docker_volume_exists() {
    docker volume inspect "$1" >/dev/null 2>&1
}

docker_image_exists() {
    docker image inspect "$1" >/dev/null 2>&1
}

validate_docker_compose_version() {
    local raw="$1"
    local major minor patch

    DOCKER_COMPOSE_VERSION=''
    DOCKER_COMPOSE_VERSION_ERROR=''
    raw="${raw%$'\r'}"
    if [[ "${raw}" =~ ^v?((0|[1-9][0-9]*))\.((0|[1-9][0-9]*))\.((0|[1-9][0-9]*))([-+][0-9A-Za-z][0-9A-Za-z.+_-]*)?$ ]]; then
        major=$((10#${BASH_REMATCH[1]}))
        minor=$((10#${BASH_REMATCH[3]}))
        patch=$((10#${BASH_REMATCH[5]}))
        DOCKER_COMPOSE_VERSION="${major}.${minor}.${patch}"
    else
        DOCKER_COMPOSE_VERSION_ERROR="Could not parse Docker Compose version '${raw}'. Expected vMAJOR.MINOR.PATCH with optional trailing metadata; Docker Compose 2.33.1 or newer is required."
        return 1
    fi

    if (( major > 2 )) ||
        (( major == 2 && (minor > 33 || (minor == 33 && patch >= 1)) )); then
        return 0
    fi
    DOCKER_COMPOSE_VERSION_ERROR="Docker Compose 2.33.1 or newer is required for gw_priority; detected ${DOCKER_COMPOSE_VERSION}."
    return 1
}

validate_docker_engine_version() {
    local raw="$1"
    local major minor patch

    DOCKER_ENGINE_VERSION=''
    DOCKER_ENGINE_VERSION_ERROR=''
    raw="${raw%$'\r'}"
    if [[ "${raw}" =~ ^v?((0|[1-9][0-9]*))\.((0|[1-9][0-9]*))\.((0|[1-9][0-9]*))([-+][0-9A-Za-z][0-9A-Za-z.+_-]*)?$ ]]; then
        major=$((10#${BASH_REMATCH[1]}))
        minor=$((10#${BASH_REMATCH[3]}))
        patch=$((10#${BASH_REMATCH[5]}))
        DOCKER_ENGINE_VERSION="${major}.${minor}.${patch}"
    else
        DOCKER_ENGINE_VERSION_ERROR="Could not parse Docker Engine server version '${raw}'. Expected vMAJOR.MINOR.PATCH with optional trailing metadata; Docker Engine 28.0.0 or newer is required."
        return 1
    fi

    if (( major >= 28 )); then
        return 0
    fi
    DOCKER_ENGINE_VERSION_ERROR="Docker Engine 28.0.0 or newer is required for gw_priority Engine API support; detected ${DOCKER_ENGINE_VERSION}."
    return 1
}

directory_has_entries() {
    local directory="$1"
    local first
    first="$(find "${directory}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ||
        die "Cannot inspect storage directory: ${directory}"
    [[ -n "${first}" ]]
}

compose_in() {
    local project_path="$1"
    shift
    (
        cd -- "${project_path}"
        docker compose --env-file .env "$@"
    )
}

export_wireguard_outputs() {
    local project_path="$1"
    local output_directory public_output peer_output temporary_directory temporary_public temporary_peer
    local public_key expected_peer actual_peer

    output_directory="${project_path}/wireguard"
    public_output="${output_directory}/${ENVIRONMENT_NAME}_wireguard_public.key"
    peer_output="${output_directory}/${ENVIRONMENT_NAME}_hub_peer.conf"
    [[ -d "${output_directory}" && ! -L "${output_directory}" ]] ||
        die "WireGuard output directory is missing or unsafe: ${output_directory}"
    chmod 0700 "${output_directory}"
    temporary_directory="$(mktemp -d -- "${output_directory}/.export.XXXXXXXXXX")" ||
        die "Could not create a temporary WireGuard export directory under ${output_directory}."
    case "${temporary_directory}" in
        "${output_directory}/.export."*) ;;
        *) die "Refusing to use an unexpected WireGuard export directory: ${temporary_directory}" ;;
    esac
    temporary_public="${temporary_directory}/public.key"
    temporary_peer="${temporary_directory}/hub_peer.conf"

    if ! compose_in "${project_path}" cp wireguard:/var/lib/wireguard/public.key "${temporary_public}"; then
        rm -rf -- "${temporary_directory}"
        die 'Could not copy the WireGuard public key from its state volume.'
    fi
    if [[ ! -f "${temporary_public}" || -L "${temporary_public}" || ! -s "${temporary_public}" ]]; then
        rm -rf -- "${temporary_directory}"
        die 'Copied WireGuard public-key output is missing or unsafe.'
    fi
    public_key="$(tr -d '\r\n' <"${temporary_public}")"
    if ! validate_wireguard_public_key "${public_key}"; then
        rm -rf -- "${temporary_directory}"
        die 'Copied WireGuard public-key output is invalid.'
    fi
    cat >"${temporary_peer}" <<EOF
# Add this peer to the public WireGuard Hub, then reload the Hub configuration.
[Peer]
# DockerVM environment: ${ENVIRONMENT_NAME}
PublicKey = ${public_key}
AllowedIPs = ${WIREGUARD_IP}/32
EOF
    expected_peer="$(printf '%s\n' \
        '# Add this peer to the public WireGuard Hub, then reload the Hub configuration.' \
        '[Peer]' \
        "# DockerVM environment: ${ENVIRONMENT_NAME}" \
        "PublicKey = ${public_key}" \
        "AllowedIPs = ${WIREGUARD_IP}/32")"
    actual_peer="$(cat "${temporary_peer}")"
    if [[ "${actual_peer}" != "${expected_peer}" ]]; then
        rm -rf -- "${temporary_directory}"
        die 'Generated WireGuard Hub peer output failed exact-content validation.'
    fi
    chmod 0644 "${temporary_public}" "${temporary_peer}"
    mv -f -- "${temporary_public}" "${public_output}"
    mv -f -- "${temporary_peer}" "${peer_output}"
    rmdir -- "${temporary_directory}" || die 'Could not remove the empty WireGuard export directory.'
}

wait_until_healthy() {
    local project_path="$1"
    local deadline desktop_id docker_id wireguard_id remote_proxy_id
    local desktop_state docker_state wireguard_state remote_proxy_state
    deadline=$((SECONDS + 600))
    while (( SECONDS < deadline )); do
        desktop_id="$(compose_in "${project_path}" ps -q desktop 2>/dev/null || true)"
        docker_id="$(compose_in "${project_path}" ps -q docker 2>/dev/null || true)"
        wireguard_id="$(compose_in "${project_path}" ps -q wireguard 2>/dev/null || true)"
        remote_proxy_id="$(compose_in "${project_path}" ps -q remote_proxy 2>/dev/null || true)"
        if [[ -n "${desktop_id}" && -n "${docker_id}" && -n "${wireguard_id}" && -n "${remote_proxy_id}" ]]; then
            desktop_state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${desktop_id}" 2>/dev/null || true)"
            docker_state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${docker_id}" 2>/dev/null || true)"
            wireguard_state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${wireguard_id}" 2>/dev/null || true)"
            remote_proxy_state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${remote_proxy_id}" 2>/dev/null || true)"
            if [[ "${desktop_state}" == healthy && "${docker_state}" == healthy && "${wireguard_state}" == healthy && "${remote_proxy_state}" == healthy ]]; then
                return 0
            fi
            if [[ "${desktop_state}" == unhealthy || "${docker_state}" == unhealthy || "${wireguard_state}" == unhealthy || "${remote_proxy_state}" == unhealthy ]]; then
                compose_in "${project_path}" logs --tail 100 desktop docker wireguard remote_proxy >&2 || true
                die "Environment became unhealthy: desktop=${desktop_state}, docker=${docker_state}, wireguard=${wireguard_state}, remote_proxy=${remote_proxy_state}."
            fi
        fi
        sleep 3
    done
    compose_in "${project_path}" logs --tail 100 desktop docker wireguard remote_proxy >&2 || true
    die "Environment did not become healthy within 600 seconds: ${project_path}"
}

expand_template_line() {
    local remaining="$1"
    local output='' key needle prefix best_key best_needle
    local best_prefix_length prefix_length

    # Always scan the unconsumed template text. Replacement values are added
    # directly to output and are never interpreted as additional placeholders.
    while true; do
        best_key=''
        best_needle=''
        best_prefix_length=-1
        for key in "${!TEMPLATE_TOKENS[@]}"; do
            needle="__${key}__"
            [[ "${remaining}" == *"${needle}"* ]] || continue
            prefix="${remaining%%"${needle}"*}"
            prefix_length=${#prefix}
            if (( best_prefix_length < 0 || prefix_length < best_prefix_length )); then
                best_key="${key}"
                best_needle="${needle}"
                best_prefix_length=${prefix_length}
            fi
        done

        (( best_prefix_length >= 0 )) || break
        output+="${remaining:0:best_prefix_length}${TEMPLATE_TOKENS[${best_key}]}"
        remaining="${remaining:$((best_prefix_length + ${#best_needle}))}"
    done
    REPLACED_TEXT="${output}${remaining}"
}

expand_template() {
    local source="$1"
    local destination="$2"
    local line token key

    while IFS= read -r token; do
        [[ -n "${token}" ]] || continue
        key="${token#__}"
        key="${key%__}"
        [[ -n "${TEMPLATE_TOKENS[${key}]+present}" ]] ||
            die "Unknown template token ${token} in ${source}."
    done < <(grep -Eo '__[A-Z][A-Z0-9_]*__' "${source}" | sort -u || true)

    : >"${destination}"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        expand_template_line "${line}"
        printf '%s\n' "${REPLACED_TEXT}" >>"${destination}"
    done <"${source}"
}

single_quote_shell_value() {
    local value="$1"
    value="${value//\'/\'\\\'\'}"
    printf "'%s'" "${value}"
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    printf '%s' "${value}"
}

env_single_quoted() {
    local value="$1"
    value="${value//\'/\\\'}"
    printf "'%s'" "${value}"
}

probe_gpu_runtime() {
    command -v nvidia-smi >/dev/null 2>&1 || return 1
    nvidia-smi -L >/dev/null 2>&1 || return 1
    docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"' || return 1

    # Avoid turning a temporary registry outage into a silent CPU-only choice.
    # If the small probe image is already local, also verify the configured
    # runtime now; the selected CUDA image is tested after the environment starts.
    if docker_image_exists 'ubuntu:26.04'; then
        docker run --rm --gpus all ubuntu:26.04 nvidia-smi -L >/dev/null
    fi
}

apply_firewall() {
    local script_path="$1"
    FIREWALL_ATTEMPTED='1'
    if (( EUID == 0 )); then
        "${script_path}"
    else
        command -v sudo >/dev/null 2>&1 || die 'sudo is required to apply the Linux firewall policy.'
        sudo -- "${script_path}"
    fi
    FIREWALL_APPLIED='1'
}

find_environment_firewall_script() {
    local project_path="$1"
    local candidate="${project_path}/configure_${ENVIRONMENT_NAME_SNAKE}_firewall.sh"
    if [[ -x "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
    fi

    # Compatibility for environments created before shell filenames used snake_case.
    candidate="${project_path}/Configure-${ENVIRONMENT_NAME}-Firewall.sh"
    if [[ -x "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
    fi
    return 1
}

on_error() {
    local status=$?
    LAST_FAILED_COMMAND="${BASH_COMMAND}"
    return "${status}"
}

on_exit() {
    local status=$?
    trap - ERR EXIT INT TERM
    set +e

    if (( status != 0 )) && [[ "${COMPLETED}" != 1 ]]; then
        warn "Generation failed${LAST_FAILED_COMMAND:+ while running: ${LAST_FAILED_COMMAND}}"

        local failed_environment_stopped='1'
        if [[ "${SWAPPED}" == 1 && -n "${TARGET_PATH}" && -d "${TARGET_PATH}" ]]; then
            if ! compose_in "${TARGET_PATH}" down --remove-orphans >/dev/null 2>&1; then
                failed_environment_stopped='0'
                warn 'The failed environment could not be stopped; its configuration and firewall policy were left in place.'
            fi
        fi

        # Keep the restrictive rules in place until the failed containers have
        # stopped, so rollback never creates an unfiltered exposure window.
        if [[ "${failed_environment_stopped}" == 1 && "${FIREWALL_ATTEMPTED}" == 1 && -n "${TARGET_PATH}" && -d "${TARGET_PATH}" ]]; then
            local failed_firewall_script
            failed_firewall_script="$(find_environment_firewall_script "${TARGET_PATH}" || true)"
            if [[ -n "${failed_firewall_script}" ]]; then
                if (( EUID == 0 )); then
                    "${failed_firewall_script}" --remove >/dev/null 2>&1 ||
                        warn 'Could not fully remove the failed environment firewall policy.'
                elif command -v sudo >/dev/null 2>&1; then
                    sudo -- "${failed_firewall_script}" --remove >/dev/null 2>&1 ||
                        warn 'Could not fully remove the failed environment firewall policy.'
                fi
            fi
        fi

        if [[ "${failed_environment_stopped}" == 1 && "${SWAPPED}" == 1 && -n "${TARGET_PATH}" && -d "${TARGET_PATH}" ]]; then
            local failed_root failed_path
            failed_root="${ROOT_PATH}/.failed"
            mkdir -p -- "${failed_root}"
            failed_path="${failed_root}/${ENVIRONMENT_NAME}.$(date +%Y%m%d-%H%M%S).$(random_suffix)"
            mv -- "${TARGET_PATH}" "${failed_path}" || true
            warn "Failed configuration preserved at ${failed_path}."
        fi

        if [[ -n "${BACKUP_PATH}" && -d "${BACKUP_PATH}" && ! -e "${TARGET_PATH}" ]]; then
            mv -- "${BACKUP_PATH}" "${TARGET_PATH}"
            local restored_firewall_ready='1'
            if [[ "${FIREWALL_ATTEMPTED}" == 1 ]]; then
                local restored_firewall_script
                restored_firewall_script="$(find_environment_firewall_script "${TARGET_PATH}" || true)"
                if [[ -n "${restored_firewall_script}" ]]; then
                    if (( EUID == 0 )); then
                        "${restored_firewall_script}" >/dev/null 2>&1 || restored_firewall_ready='0'
                    elif command -v sudo >/dev/null 2>&1; then
                        sudo -- "${restored_firewall_script}" >/dev/null 2>&1 || restored_firewall_ready='0'
                    else
                        restored_firewall_ready='0'
                    fi
                else
                    restored_firewall_ready='0'
                fi
            fi
            if [[ "${restored_firewall_ready}" == 1 ]]; then
                compose_in "${TARGET_PATH}" up -d >/dev/null 2>&1 ||
                    warn "The previous configuration was restored but could not be restarted: ${TARGET_PATH}"
            else
                warn 'The previous firewall policy could not be reapplied; the restored environment was left stopped.'
            fi
        elif [[ "${OLD_STOPPED}" == 1 && "${OLD_TARGET_EXISTED}" == 1 && -d "${TARGET_PATH}" ]]; then
            compose_in "${TARGET_PATH}" up -d >/dev/null 2>&1 ||
                warn "The previous environment could not be restarted: ${TARGET_PATH}"
        fi
    fi

    if [[ -n "${STAGING_PATH}" && -d "${STAGING_PATH}" ]]; then
        case "${STAGING_PATH}" in
            "${ROOT_PATH}/.staging/"*) rm -rf -- "${STAGING_PATH}" ;;
            *) warn "Refused to remove unexpected staging path: ${STAGING_PATH}" ;;
        esac
    fi

    exit "${status}"
}

random_suffix() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        tr -d '-' </proc/sys/kernel/random/uuid | cut -c1-12
    else
        printf '%s-%s\n' "$$" "${RANDOM}"
    fi
}

derive_ssh_public_key() {
    local private_key="$1"
    ssh-keygen -y -P '' -f "${private_key}" 2>/dev/null
}

validate_ssh_private_key() {
    local private_key="$1"
    local first_line public_key details

    [[ -f "${private_key}" && ! -L "${private_key}" && -s "${private_key}" ]] || return 1
    IFS= read -r first_line <"${private_key}" || return 1
    [[ "${first_line}" == '-----BEGIN RSA PRIVATE KEY-----' ]] || return 1
    public_key="$(derive_ssh_public_key "${private_key}")" || return 1
    [[ "${public_key}" == ssh-rsa\ * ]] || return 1
    details="$(printf '%s\n' "${public_key}" | ssh-keygen -l -E sha256 -f - 2>/dev/null)" || return 1
    [[ "${details}" == 4096\ * && "${details}" == *'(RSA)' ]]
}

validate_matching_ssh_public_key() {
    local private_key="$1"
    local public_key_file="$2"
    local derived stored nonempty_lines

    [[ -f "${public_key_file}" && ! -L "${public_key_file}" && -s "${public_key_file}" ]] || return 1
    nonempty_lines="$(awk 'NF { count += 1 } END { print count + 0 }' "${public_key_file}")"
    [[ "${nonempty_lines}" == 1 ]] || return 1
    derived="$(derive_ssh_public_key "${private_key}")" || return 1
    stored="$(awk 'NF { print $1 " " $2; exit }' "${public_key_file}")"
    [[ "${stored}" == "${derived}" ]]
}

write_ssh_public_key() {
    local private_key="$1"
    local public_key_file="$2"
    local public_key

    public_key="$(derive_ssh_public_key "${private_key}")" ||
        die "Could not derive the public key from ${private_key}."
    printf '%s %s@%s\n' "${public_key}" "${ACCOUNT_NAME}" "${ENVIRONMENT_NAME}" >"${public_key_file}"
    chmod 0644 "${public_key_file}"
}

prepare_ssh_identity() {
    local old_private old_public staged_private staged_public generated_public fingerprint_details
    local reuse_existing='0'

    SSH_PRIVATE_KEY_FILE="${ENVIRONMENT_NAME}_ssh.pem"
    SSH_PUBLIC_KEY_FILE="${ENVIRONMENT_NAME}_ssh.pub"
    old_private="${TARGET_PATH}/${SSH_PRIVATE_KEY_FILE}"
    old_public="${TARGET_PATH}/${SSH_PUBLIC_KEY_FILE}"
    staged_private="${STAGING_PATH}/${SSH_PRIVATE_KEY_FILE}"
    staged_public="${STAGING_PATH}/${SSH_PUBLIC_KEY_FILE}"
    mkdir -p -- "${STAGING_PATH}/secrets"

    if [[ "${ROTATE_SSH_KEY}" != 1 && -e "${old_private}" ]]; then
        validate_ssh_private_key "${old_private}" ||
            die "Existing SSH private key is not an unencrypted RSA-4096 PEM key; use --rotate-ssh-key to replace it: ${old_private}"
        if [[ -e "${old_public}" ]]; then
            validate_matching_ssh_public_key "${old_private}" "${old_public}" ||
                die "Existing SSH public key does not match its private key; use --rotate-ssh-key to replace the pair: ${old_public}"
        fi
        install -m 0600 -- "${old_private}" "${staged_private}"
        reuse_existing='1'
    elif [[ "${ROTATE_SSH_KEY}" != 1 && -e "${old_public}" ]]; then
        die "Existing SSH public key has no reusable private key; use --rotate-ssh-key to replace the pair: ${old_public}"
    fi

    if [[ "${reuse_existing}" != 1 ]]; then
        [[ ! -e "${staged_private}" && ! -e "${staged_private}.pub" && ! -e "${staged_public}" ]] ||
            die "Refusing to overwrite an unexpected staged SSH key: ${staged_private}"
        ssh-keygen -q -t rsa -b 4096 -m PEM -N '' \
            -C "${ACCOUNT_NAME}@${ENVIRONMENT_NAME}" -f "${staged_private}"
        generated_public="${staged_private}.pub"
        [[ -f "${generated_public}" ]] || die 'ssh-keygen did not create the expected public key.'
        rm -f -- "${generated_public}"
    fi

    validate_ssh_private_key "${staged_private}" ||
        die "Generated or reused SSH private key failed validation: ${staged_private}"
    chmod 0600 "${staged_private}"
    write_ssh_public_key "${staged_private}" "${staged_public}"
    validate_matching_ssh_public_key "${staged_private}" "${staged_public}" ||
        die 'Generated SSH public key does not match the private key.'
    install -m 0600 -- "${staged_public}" "${STAGING_PATH}/secrets/ssh_authorized_keys"

    fingerprint_details="$(ssh-keygen -l -E sha256 -f "${staged_public}" 2>/dev/null)" ||
        die 'Could not calculate the SSH public-key fingerprint.'
    SSH_KEY_FINGERPRINT="$(awk '{ print $2; exit }' <<<"${fingerprint_details}")"
    [[ "${SSH_KEY_FINGERPRINT}" == SHA256:* ]] || die 'Unexpected SSH public-key fingerprint format.'
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --environment|--environment-name)
                require_option_value "$1" "$#"; ENVIRONMENT_NAME="$2"; shift 2 ;;
            --environment=*|--environment-name=*) ENVIRONMENT_NAME="${1#*=}"; shift ;;
            --account|--account-name)
                require_option_value "$1" "$#"; ACCOUNT_NAME="$2"; shift 2 ;;
            --account=*|--account-name=*) ACCOUNT_NAME="${1#*=}"; shift ;;
            --password)
                require_option_value "$1" "$#"; PASSWORD_VALUE="$2"; PASSWORD_SOURCE='argument'; shift 2 ;;
            --password=*) PASSWORD_VALUE="${1#*=}"; PASSWORD_SOURCE='argument'; shift ;;
            --password-file)
                require_option_value "$1" "$#"; PASSWORD_FILE="$2"; PASSWORD_SOURCE='file'; shift 2 ;;
            --password-file=*) PASSWORD_FILE="${1#*=}"; PASSWORD_SOURCE='file'; shift ;;
            --password-stdin) PASSWORD_SOURCE='stdin'; shift ;;
            --host-address)
                require_option_value "$1" "$#"; HOST_ADDRESS="$2"; shift 2 ;;
            --host-address=*) HOST_ADDRESS="${1#*=}"; shift ;;
            --remote-subnet)
                require_option_value "$1" "$#"; REMOTE_SUBNET="$2"; shift 2 ;;
            --remote-subnet=*) REMOTE_SUBNET="${1#*=}"; shift ;;
            --ssh-port)
                require_option_value "$1" "$#"; SSH_PORT="$2"; shift 2 ;;
            --ssh-port=*) SSH_PORT="${1#*=}"; shift ;;
            --rdp-port)
                require_option_value "$1" "$#"; RDP_PORT="$2"; shift 2 ;;
            --rdp-port=*) RDP_PORT="${1#*=}"; shift ;;
            --wireguard-hub-endpoint)
                require_option_value "$1" "$#"; WIREGUARD_HUB_ENDPOINT="$2"; shift 2 ;;
            --wireguard-hub-endpoint=*) WIREGUARD_HUB_ENDPOINT="${1#*=}"; shift ;;
            --wireguard-hub-public-key)
                require_option_value "$1" "$#"; WIREGUARD_HUB_PUBLIC_KEY="$2"; shift 2 ;;
            --wireguard-hub-public-key=*) WIREGUARD_HUB_PUBLIC_KEY="${1#*=}"; shift ;;
            --wireguard-address)
                require_option_value "$1" "$#"; WIREGUARD_ADDRESS="$2"; shift 2 ;;
            --wireguard-address=*) WIREGUARD_ADDRESS="${1#*=}"; shift ;;
            --wireguard-mtu)
                require_option_value "$1" "$#"; WIREGUARD_MTU="$2"; shift 2 ;;
            --wireguard-mtu=*) WIREGUARD_MTU="${1#*=}"; shift ;;
            --wireguard-keepalive)
                require_option_value "$1" "$#"; WIREGUARD_KEEPALIVE="$2"; shift 2 ;;
            --wireguard-keepalive=*) WIREGUARD_KEEPALIVE="${1#*=}"; shift ;;
            --desktop-cpus)
                require_option_value "$1" "$#"; DESKTOP_CPUS="$2"; shift 2 ;;
            --desktop-cpus=*) DESKTOP_CPUS="${1#*=}"; shift ;;
            --desktop-memory)
                require_option_value "$1" "$#"; DESKTOP_MEMORY="$2"; shift 2 ;;
            --desktop-memory=*) DESKTOP_MEMORY="${1#*=}"; shift ;;
            --dind-cpus)
                require_option_value "$1" "$#"; DIND_CPUS="$2"; shift 2 ;;
            --dind-cpus=*) DIND_CPUS="${1#*=}"; shift ;;
            --dind-memory)
                require_option_value "$1" "$#"; DIND_MEMORY="$2"; shift 2 ;;
            --dind-memory=*) DIND_MEMORY="${1#*=}"; shift ;;
            --uid)
                require_option_value "$1" "$#"; ACCOUNT_UID="$2"; shift 2 ;;
            --uid=*) ACCOUNT_UID="${1#*=}"; shift ;;
            --gid)
                require_option_value "$1" "$#"; ACCOUNT_GID="$2"; shift 2 ;;
            --gid=*) ACCOUNT_GID="${1#*=}"; shift ;;
            --docker-version)
                require_option_value "$1" "$#"; DOCKER_VERSION="$2"; shift 2 ;;
            --docker-version=*) DOCKER_VERSION="${1#*=}"; shift ;;
            --gpu)
                require_option_value "$1" "$#"; GPU_MODE="${2,,}"; shift 2 ;;
            --gpu=*) GPU_MODE="${1#*=}"; GPU_MODE="${GPU_MODE,,}"; shift ;;
            --cuda-image)
                require_option_value "$1" "$#"; CUDA_IMAGE="$2"; CUDA_IMAGE_EXPLICIT='1'; shift 2 ;;
            --cuda-image=*) CUDA_IMAGE="${1#*=}"; CUDA_IMAGE_EXPLICIT='1'; shift ;;
            --nvidia-toolkit-version)
                require_option_value "$1" "$#"; NVIDIA_CONTAINER_TOOLKIT_VERSION="$2"; NVIDIA_TOOLKIT_VERSION_EXPLICIT='1'; shift 2 ;;
            --nvidia-toolkit-version=*) NVIDIA_CONTAINER_TOOLKIT_VERSION="${1#*=}"; NVIDIA_TOOLKIT_VERSION_EXPLICIT='1'; shift ;;
            --root)
                require_option_value "$1" "$#"; ROOT_PATH="$2"; shift 2 ;;
            --root=*) ROOT_PATH="${1#*=}"; shift ;;
            --replace) REPLACE='1'; shift ;;
            --migrate-legacy-home) MIGRATE_LEGACY_HOME='yes'; shift ;;
            --no-migrate-legacy-home) MIGRATE_LEGACY_HOME='no'; shift ;;
            --allow-docker-version-change) ALLOW_DOCKER_VERSION_CHANGE='1'; shift ;;
            --rotate-ssh-key) ROTATE_SSH_KEY='1'; shift ;;
            --use-buildkit) USE_BUILDKIT='1'; shift ;;
            --generate-only) GENERATE_ONLY='1'; shift ;;
            --apply-firewall) FIREWALL_MODE='apply'; shift ;;
            --skip-firewall) FIREWALL_MODE='skip'; shift ;;
            -h|--help) usage; exit 0 ;;
            --) shift; (( $# == 0 )) || die "Unexpected positional argument: $1" ;;
            -*) die "Unknown option: $1" ;;
            *) die "Unexpected positional argument: $1" ;;
        esac
    done
}

read_password() {
    local first second permission
    case "${PASSWORD_SOURCE}" in
        argument)
            warn 'A password supplied as a command-line argument may be visible in process listings and shell history.'
            ;;
        file)
            [[ -f "${PASSWORD_FILE}" ]] || die "Password file does not exist: ${PASSWORD_FILE}"
            permission="$(stat -c '%a' "${PASSWORD_FILE}")"
            [[ "${permission}" =~ ^(400|600)$ ]] || die "Password file must have mode 400 or 600: ${PASSWORD_FILE}"
            IFS= read -r PASSWORD_VALUE <"${PASSWORD_FILE}" || true
            ;;
        stdin)
            IFS= read -r PASSWORD_VALUE || die 'Could not read the password from stdin.'
            ;;
        prompt)
            is_interactive || die 'Use --password-file or --password-stdin in non-interactive mode.'
            while true; do
                read -r -s -p 'Login password: ' first
                printf '\n'
                read -r -s -p 'Confirm login password: ' second
                printf '\n'
                if [[ -z "${first}" ]]; then
                    warn 'The password must not be empty.'
                    continue
                fi
                if [[ "${first}" != "${second}" ]]; then
                    warn 'Passwords do not match.'
                    continue
                fi
                PASSWORD_VALUE="${first}"
                break
            done
            ;;
        *) die "Internal error: unknown password source ${PASSWORD_SOURCE}." ;;
    esac

    [[ -n "${PASSWORD_VALUE}" ]] || die 'The password must not be empty.'
    validate_no_line_breaks 'Password' "${PASSWORD_VALUE}"
}

prepare_inputs() {
    local old_env="${TARGET_PATH}/.env"
    local default_value old_value old_gpu_enabled default_uid default_gid desktop_memory_bytes dind_memory_bytes

    if [[ -z "${ACCOUNT_NAME}" ]]; then
        old_value="$(read_environment_value "${old_env}" ACCOUNT_NAME || true)"
        read_with_default ACCOUNT_NAME 'Linux account name' "${old_value:-${ENVIRONMENT_NAME}}"
    fi
    ACCOUNT_NAME="${ACCOUNT_NAME,,}"
    [[ "${ACCOUNT_NAME}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid Linux account name.'
    case "${ACCOUNT_NAME}" in
        root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|operator|list|irc|_apt|nobody|ubuntu|systemd-network|systemd-journal|messagebus|sshd|_ssh|xrdp|adm|tty|disk|dialout|fax|voice|cdrom|floppy|tape|sudo|audio|dip|src|shadow|utmp|video|sasl|plugdev|staff|users|nogroup|ssl-cert|input|sgx|clock|kvm|render)
            die "Reserved Ubuntu user/group name: ${ACCOUNT_NAME}" ;;
    esac

    old_value="$(read_environment_value "${old_env}" DOCKER_VERSION || true)"
    default_value="${old_value:-29.6.2}"
    [[ -n "${DOCKER_VERSION}" ]] || read_with_default DOCKER_VERSION 'Docker/DinD version' "${default_value}"
    [[ "${DOCKER_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Docker version must use X.Y.Z format.'
    if [[ -n "${old_value}" && "${old_value}" != "${DOCKER_VERSION}" && "${ALLOW_DOCKER_VERSION_CHANGE}" != 1 ]]; then
        die "Changing Docker from ${old_value} to ${DOCKER_VERSION} requires --allow-docker-version-change."
    fi

    if [[ "${CUDA_IMAGE_EXPLICIT}" != 1 ]]; then
        old_value="$(read_environment_value "${old_env}" CUDA_IMAGE || true)"
        [[ -z "${old_value}" ]] || CUDA_IMAGE="${old_value}"
    fi
    if [[ "${NVIDIA_TOOLKIT_VERSION_EXPLICIT}" != 1 ]]; then
        old_value="$(read_environment_value "${old_env}" NVIDIA_CONTAINER_TOOLKIT_VERSION || true)"
        [[ -z "${old_value}" ]] || NVIDIA_CONTAINER_TOOLKIT_VERSION="${old_value}"
    fi

    detect_lan_defaults
    old_value="$(read_environment_value "${old_env}" HOST_ADDRESS || true)"
    default_value="${DETECTED_HOST_ADDRESS}"
    if [[ -n "${old_value}" ]] && validate_host_ipv4 "${old_value}" && host_has_address "${old_value}"; then
        default_value="${old_value}"
    elif [[ -n "${old_value}" ]]; then
        warn "The previous host address is no longer assigned; using the detected address ${DETECTED_HOST_ADDRESS} as the default."
    fi
    [[ -n "${HOST_ADDRESS}" ]] || read_with_default HOST_ADDRESS 'Host LAN IPv4 address' "${default_value}"
    validate_host_ipv4 "${HOST_ADDRESS}" || die "Invalid LAN host IPv4 address: ${HOST_ADDRESS}"
    host_has_address "${HOST_ADDRESS}" || die "IPv4 address is not assigned to this host: ${HOST_ADDRESS}"

    old_value="$(read_environment_value "${old_env}" REMOTE_SUBNET || true)"
    default_value="${DETECTED_REMOTE_SUBNET}"
    if [[ -n "${old_value}" ]] && validate_cidr "${old_value}"; then
        default_value="${old_value}"
    fi
    [[ -n "${REMOTE_SUBNET}" ]] || read_with_default REMOTE_SUBNET 'Allowed remote CIDR' "${default_value}"
    validate_cidr "${REMOTE_SUBNET}" || die "Invalid or overly broad CIDR: ${REMOTE_SUBNET}"

    old_value="$(read_environment_value "${old_env}" WIREGUARD_HUB_ENDPOINT || true)"
    if [[ -z "${WIREGUARD_HUB_ENDPOINT}" ]]; then
        read_required_with_default WIREGUARD_HUB_ENDPOINT 'Public WireGuard Hub endpoint (IPv4-or-hostname:port)' "${old_value}" '--wireguard-hub-endpoint'
    fi
    validate_no_line_breaks 'WireGuard Hub endpoint' "${WIREGUARD_HUB_ENDPOINT}"
    validate_wireguard_endpoint "${WIREGUARD_HUB_ENDPOINT}" ||
        die 'WireGuard Hub endpoint must use valid IPv4-or-hostname:port syntax; IPv6 literals are not supported.'

    old_value="$(read_environment_value "${old_env}" WIREGUARD_HUB_PUBLIC_KEY || true)"
    if [[ -z "${WIREGUARD_HUB_PUBLIC_KEY}" ]]; then
        read_required_with_default WIREGUARD_HUB_PUBLIC_KEY 'WireGuard Hub public key' "${old_value}" '--wireguard-hub-public-key'
    fi
    validate_no_line_breaks 'WireGuard Hub public key' "${WIREGUARD_HUB_PUBLIC_KEY}"
    validate_wireguard_public_key "${WIREGUARD_HUB_PUBLIC_KEY}" ||
        die 'WireGuard Hub public key must be a valid, non-zero base64-encoded 32-byte key.'

    old_value="$(read_environment_value "${old_env}" WIREGUARD_ADDRESS || true)"
    if [[ -z "${WIREGUARD_ADDRESS}" ]]; then
        if [[ -n "${old_value}" ]]; then
            default_value="${old_value}"
        else
            default_value="$(select_default_wireguard_address)" ||
                die 'No unused default WireGuard address remains in 10.200.0.10-10.200.0.254.'
        fi
        read_with_default WIREGUARD_ADDRESS 'WireGuard environment IPv4/CIDR' "${default_value}"
    fi
    validate_wireguard_address "${WIREGUARD_ADDRESS}" ||
        die 'WireGuard address must be a usable IPv4 host address with a /8 through /29 prefix.'
    WIREGUARD_ADDRESS="$(canonicalize_wireguard_address "${WIREGUARD_ADDRESS}")" ||
        die 'Could not canonicalize the validated WireGuard address.'
    WIREGUARD_IP="${WIREGUARD_ADDRESS%/*}"
    if wireguard_ip_in_use "${WIREGUARD_IP}"; then
        die "WireGuard IP ${WIREGUARD_IP} is already assigned to another environment under ${ROOT_PATH}."
    fi
    WIREGUARD_NETWORK="$(network_cidr "${WIREGUARD_IP}" "$((10#${WIREGUARD_ADDRESS##*/}))")"
    if cidr_ranges_overlap "${REMOTE_SUBNET}" "${WIREGUARD_NETWORK}"; then
        die "WireGuard network ${WIREGUARD_NETWORK} overlaps the LAN remote subnet ${REMOTE_SUBNET}."
    fi

    old_value="$(read_environment_value "${old_env}" WIREGUARD_MTU || true)"
    default_value="${old_value:-1380}"
    [[ -n "${WIREGUARD_MTU}" ]] || read_with_default WIREGUARD_MTU 'WireGuard MTU' "${default_value}"
    [[ "${WIREGUARD_MTU}" =~ ^[0-9]{1,5}$ ]] || die 'WireGuard MTU must be an integer from 1280 through 1420.'
    WIREGUARD_MTU=$((10#${WIREGUARD_MTU}))
    (( WIREGUARD_MTU >= 1280 && WIREGUARD_MTU <= 1420 )) ||
        die 'WireGuard MTU must be an integer from 1280 through 1420.'

    old_value="$(read_environment_value "${old_env}" WIREGUARD_KEEPALIVE || true)"
    default_value="${old_value:-25}"
    [[ -n "${WIREGUARD_KEEPALIVE}" ]] || read_with_default WIREGUARD_KEEPALIVE 'WireGuard persistent keepalive seconds' "${default_value}"
    [[ "${WIREGUARD_KEEPALIVE}" =~ ^[0-9]{1,5}$ ]] || die 'WireGuard keepalive must be an integer from 0 through 65535.'
    WIREGUARD_KEEPALIVE=$((10#${WIREGUARD_KEEPALIVE}))
    (( WIREGUARD_KEEPALIVE >= 0 && WIREGUARD_KEEPALIVE <= 65535 )) ||
        die 'WireGuard keepalive must be an integer from 0 through 65535.'

    collect_existing_environment_ports "${old_env}"
    if [[ "${SSH_PORT}" == 0 ]]; then
        old_value="$(read_environment_value "${old_env}" SSH_PORT || true)"
        if validate_port_number "${old_value}" && (( 10#${old_value} != 3389 )); then
            default_value="$((10#${old_value}))"
        else
            default_value="$(find_free_port 2222)" || die 'No free SSH port is available.'
        fi
        read_with_default SSH_PORT 'Host SSH port' "${default_value}"
    fi
    if [[ "${RDP_PORT}" == 0 ]]; then
        old_value="$(read_environment_value "${old_env}" RDP_PORT || true)"
        if validate_port_number "${old_value}" && (( 10#${old_value} >= 3390 )); then
            default_value="$((10#${old_value}))"
        else
            default_value="$(find_free_port 3390)" || die 'No free RDP port is available.'
        fi
        read_with_default RDP_PORT 'Host RDP port (3389 is reserved)' "${default_value}"
    fi
    validate_port_number "${SSH_PORT}" || die "Invalid SSH port: ${SSH_PORT}"
    validate_port_number "${RDP_PORT}" || die "Invalid RDP port: ${RDP_PORT}"
    SSH_PORT=$((10#${SSH_PORT}))
    RDP_PORT=$((10#${RDP_PORT}))
    (( SSH_PORT != 3389 && RDP_PORT != 3389 )) || die 'Host port 3389 is reserved and must never be used or modified.'
    (( RDP_PORT >= 3390 )) || die 'The RDP host port must be 3390 or higher.'
    (( SSH_PORT != RDP_PORT )) || die 'SSH and RDP ports must be different.'
    for default_value in "${SSH_PORT}" "${RDP_PORT}"; do
        if port_is_listening "${default_value}" && [[ -z "${ALLOWED_EXISTING_PORTS[${default_value}]:-}" ]]; then
            die "Host TCP port is already in use: ${default_value}"
        fi
    done

    detect_docker_resources
    old_value="$(read_environment_value "${old_env}" DESKTOP_CPUS || true)"
    default_value="$(( BACKEND_CPUS < 2 ? BACKEND_CPUS : 2 ))"
    validate_cpu_value "${old_value}" && default_value="${old_value}"
    [[ -n "${DESKTOP_CPUS}" ]] || read_with_default DESKTOP_CPUS 'Desktop CPU cores (-1 for unlimited)' "${default_value}"

    old_value="$(read_environment_value "${old_env}" DIND_CPUS || true)"
    default_value="$(( BACKEND_CPUS < 4 ? BACKEND_CPUS : 4 ))"
    validate_cpu_value "${old_value}" && default_value="${old_value}"
    [[ -n "${DIND_CPUS}" ]] || read_with_default DIND_CPUS 'DinD CPU cores (-1 for unlimited)' "${default_value}"

    old_value="$(read_environment_value "${old_env}" DESKTOP_MEMORY || true)"
    default_value='4g'
    normalise_memory_value "${old_value}" >/dev/null 2>&1 && default_value="${old_value,,}"
    [[ -n "${DESKTOP_MEMORY}" ]] || read_with_default DESKTOP_MEMORY 'Desktop RAM (-1 for unlimited)' "${default_value}"

    old_value="$(read_environment_value "${old_env}" DIND_MEMORY || true)"
    default_value='8g'
    normalise_memory_value "${old_value}" >/dev/null 2>&1 && default_value="${old_value,,}"
    [[ -n "${DIND_MEMORY}" ]] || read_with_default DIND_MEMORY 'DinD RAM (-1 for unlimited)' "${default_value}"
    validate_cpu_value "${DESKTOP_CPUS}" || die 'Desktop CPU must be -1 (unlimited) or a number greater than or equal to 0.25.'
    validate_cpu_value "${DIND_CPUS}" || die 'DinD CPU must be -1 (unlimited) or a number greater than or equal to 0.25.'
    DESKTOP_MEMORY="$(normalise_memory_value "${DESKTOP_MEMORY}")" || die 'Desktop RAM must be -1 (unlimited) or use a value such as 4g or 4096m.'
    DIND_MEMORY="$(normalise_memory_value "${DIND_MEMORY}")" || die 'DinD RAM must be -1 (unlimited) or use a value such as 8g or 8192m.'

    desktop_memory_bytes='0'
    if [[ "${DESKTOP_MEMORY}" != -1 ]]; then
        desktop_memory_bytes="$(memory_bytes "${DESKTOP_MEMORY}")"
        (( desktop_memory_bytes >= 536870912 )) || die 'Desktop RAM must be at least 512m or -1 (unlimited).'
    fi
    dind_memory_bytes='0'
    if [[ "${DIND_MEMORY}" != -1 ]]; then
        dind_memory_bytes="$(memory_bytes "${DIND_MEMORY}")"
        (( dind_memory_bytes >= 536870912 )) || die 'DinD RAM must be at least 512m or -1 (unlimited).'
    fi

    if { [[ "${DESKTOP_CPUS}" != -1 ]] && awk -v value="${DESKTOP_CPUS}" -v host="${BACKEND_CPUS}" 'BEGIN { exit !(value > host) }'; } ||
        { [[ "${DIND_CPUS}" != -1 ]] && awk -v value="${DIND_CPUS}" -v host="${BACKEND_CPUS}" 'BEGIN { exit !(value > host) }'; }; then
        warn "A service CPU limit exceeds Docker capacity (${BACKEND_CPUS} CPUs)."
    fi
    if { [[ "${DESKTOP_MEMORY}" != -1 ]] && (( desktop_memory_bytes > BACKEND_MEMORY_BYTES )); } ||
        { [[ "${DIND_MEMORY}" != -1 ]] && (( dind_memory_bytes > BACKEND_MEMORY_BYTES )); }; then
        warn 'A service RAM limit exceeds Docker backend memory.'
    fi
    if [[ "${DESKTOP_MEMORY}" != -1 && "${DIND_MEMORY}" != -1 ]] &&
        (( desktop_memory_bytes + dind_memory_bytes > BACKEND_MEMORY_BYTES )); then
        warn 'Combined service RAM limits exceed Docker backend memory.'
    fi

    default_uid="$(id -u)"; default_gid="$(id -g)"
    (( default_uid >= 1000 )) || default_uid='1001'
    (( default_gid >= 1000 )) || default_gid='1001'
    old_value="$(read_environment_value "${old_env}" ACCOUNT_UID || true)"
    [[ -n "${ACCOUNT_UID}" ]] || read_with_default ACCOUNT_UID 'Container account UID' "${old_value:-${default_uid}}"
    old_value="$(read_environment_value "${old_env}" ACCOUNT_GID || true)"
    [[ -n "${ACCOUNT_GID}" ]] || read_with_default ACCOUNT_GID 'Container account GID' "${old_value:-${default_gid}}"
    [[ "${ACCOUNT_UID}" =~ ^[0-9]+$ && "${ACCOUNT_GID}" =~ ^[0-9]+$ ]] || die 'UID and GID must be integers.'
    ACCOUNT_UID=$((10#${ACCOUNT_UID})); ACCOUNT_GID=$((10#${ACCOUNT_GID}))
    (( ACCOUNT_UID >= 1000 && ACCOUNT_UID <= 60000 && ACCOUNT_GID >= 1000 && ACCOUNT_GID <= 60000 )) ||
        die 'UID and GID must be between 1000 and 60000.'

    case "${GPU_MODE}" in
        auto)
            if probe_gpu_runtime; then
                GPU_ENABLED='1'
                info 'NVIDIA GPU and Docker GPU runtime detected; GPU support will be enabled.'
            else
                GPU_ENABLED='0'
                old_gpu_enabled="$(read_environment_value "${old_env}" GPU_ENABLED || true)"
                if [[ "${old_gpu_enabled}" == 1 ]]; then
                    die 'The existing environment has GPU enabled, but the current host/runtime probe failed. Refusing a silent CPU-only replacement; repair GPU access or use --gpu off explicitly.'
                fi
                warn 'GPU auto-detection did not pass both host and Docker runtime probes; GPU support is disabled.'
            fi
            ;;
        on)
            probe_gpu_runtime || die 'GPU mode was requested, but nvidia-smi or the NVIDIA Container Toolkit probe failed.'
            GPU_ENABLED='1'
            ;;
        off) GPU_ENABLED='0' ;;
        *) die '--gpu must be auto, on, or off.' ;;
    esac
    [[ -n "${CUDA_IMAGE}" ]] || die 'CUDA image must not be empty.'
    validate_no_line_breaks 'CUDA image' "${CUDA_IMAGE}"
    [[ "${CUDA_IMAGE}" =~ ^[A-Za-z0-9._/@:-]+$ ]] || die 'Invalid CUDA image reference.'
    [[ "${NVIDIA_CONTAINER_TOOLKIT_VERSION}" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || die 'Invalid NVIDIA Container Toolkit version.'

    read_password

    if [[ "${OLD_TARGET_EXISTED}" == 1 && "${REPLACE}" != 1 ]]; then
        is_interactive || die "Environment exists; rerun with --replace: ${TARGET_PATH}"
        local confirmation
        read -r -p "Type exactly 'REPLACE ${ENVIRONMENT_NAME}' to replace the existing environment: " confirmation
        [[ "${confirmation}" == "REPLACE ${ENVIRONMENT_NAME}" ]] || die 'Environment replacement cancelled.'
        REPLACE='1'
    fi

    if [[ "${FIREWALL_MODE}" == ask ]]; then
        if [[ "${GENERATE_ONLY}" == 1 ]]; then
            FIREWALL_MODE='skip'
        elif read_yes_no 'Apply the LAN-only Docker firewall policy with sudo?' 'Y'; then
            FIREWALL_MODE='apply'
        else
            local answer_status=$?
            FIREWALL_MODE='skip'
            (( answer_status != 2 )) || warn 'Non-interactive run: firewall application skipped; use --apply-firewall to require it.'
        fi
    fi
}

write_environment_files() {
    local image_tag storage_env firewall_chain chain_prefix chain_hash firewall_script gpu_status gpu_test_command
    local desktop_cpu_limit desktop_memory_limit dind_cpu_limit dind_memory_limit
    local desktop_cpu_display desktop_memory_display dind_cpu_display dind_memory_display
    local desktop_cpus_unlimited desktop_memory_unlimited dind_cpus_unlimited dind_memory_unlimited
    local local_rdp_file remote_rdp_file wireguard_public_key_file wireguard_hub_peer_file wireguard_state_volume
    image_tag="26.04-$(date -u +%Y%m%d%H%M%S)-$(random_suffix)"
    storage_env="$(env_single_quoted "${STORAGE_PATH}")"
    chain_prefix="${ENVIRONMENT_NAME//-/_}"
    chain_prefix="${chain_prefix:0:10}"
    chain_hash="$(printf '%s' "${ENVIRONMENT_NAME}" | cksum | awk '{ print $1 }')"
    firewall_chain="DVM_${chain_prefix}_${chain_hash}"
    firewall_chain="${firewall_chain:0:25}"
    firewall_script="${TARGET_PATH}/configure_${ENVIRONMENT_NAME_SNAKE}_firewall.sh"
    local_rdp_file="${ENVIRONMENT_NAME}_local.rdp"
    remote_rdp_file="${ENVIRONMENT_NAME}_remote.rdp"
    wireguard_public_key_file="wireguard/${ENVIRONMENT_NAME}_wireguard_public.key"
    wireguard_hub_peer_file="wireguard/${ENVIRONMENT_NAME}_hub_peer.conf"
    wireguard_state_volume="${ENVIRONMENT_NAME}_wireguard_state"
    gpu_status='disabled'
    gpu_test_command='./test_gpu.sh'
    if [[ "${GPU_ENABLED}" == 1 ]]; then
        gpu_status="enabled (${CUDA_IMAGE})"
        gpu_test_command='./test_gpu.sh'
    fi

    desktop_cpu_limit='cpus: "${DESKTOP_CPUS}"'
    desktop_memory_limit='mem_limit: ${DESKTOP_MEMORY}'
    dind_cpu_limit='cpus: "${DIND_CPUS}"'
    dind_memory_limit='mem_limit: ${DIND_MEMORY}'
    desktop_cpu_display="$(resource_display_value "${DESKTOP_CPUS}")"
    desktop_memory_display="$(resource_display_value "${DESKTOP_MEMORY}")"
    dind_cpu_display="$(resource_display_value "${DIND_CPUS}")"
    dind_memory_display="$(resource_display_value "${DIND_MEMORY}")"
    desktop_cpus_unlimited='false'
    desktop_memory_unlimited='false'
    dind_cpus_unlimited='false'
    dind_memory_unlimited='false'
    if [[ "${DESKTOP_CPUS}" == -1 ]]; then
        desktop_cpu_limit='# CPU limit omitted: unlimited (-1).'
        desktop_cpus_unlimited='true'
    fi
    if [[ "${DESKTOP_MEMORY}" == -1 ]]; then
        desktop_memory_limit='# Memory limit omitted: unlimited (-1).'
        desktop_memory_unlimited='true'
    fi
    if [[ "${DIND_CPUS}" == -1 ]]; then
        dind_cpu_limit='# CPU limit omitted: unlimited (-1).'
        dind_cpus_unlimited='true'
    fi
    if [[ "${DIND_MEMORY}" == -1 ]]; then
        dind_memory_limit='# Memory limit omitted: unlimited (-1).'
        dind_memory_unlimited='true'
    fi

    cat >"${STAGING_PATH}/.env" <<EOF
ENVIRONMENT_NAME=${ENVIRONMENT_NAME}
ACCOUNT_NAME=${ACCOUNT_NAME}
ACCOUNT_UID=${ACCOUNT_UID}
ACCOUNT_GID=${ACCOUNT_GID}
HOST_ADDRESS=${HOST_ADDRESS}
SSH_PORT=${SSH_PORT}
RDP_PORT=${RDP_PORT}
REMOTE_SUBNET=${REMOTE_SUBNET}
WIREGUARD_HUB_ENDPOINT=${WIREGUARD_HUB_ENDPOINT}
WIREGUARD_HUB_PUBLIC_KEY=${WIREGUARD_HUB_PUBLIC_KEY}
WIREGUARD_ADDRESS=${WIREGUARD_ADDRESS}
WIREGUARD_NETWORK=${WIREGUARD_NETWORK}
WIREGUARD_MTU=${WIREGUARD_MTU}
WIREGUARD_KEEPALIVE=${WIREGUARD_KEEPALIVE}
# A resource value of -1 means unlimited; the corresponding Compose limit is omitted.
DESKTOP_CPUS=${DESKTOP_CPUS}
DESKTOP_MEMORY=${DESKTOP_MEMORY}
DIND_CPUS=${DIND_CPUS}
DIND_MEMORY=${DIND_MEMORY}
DOCKER_VERSION=${DOCKER_VERSION}
IMAGE_TAG=${image_tag}
TZ=Asia/Seoul
HOST_PLATFORM=linux
GPU_ENABLED=${GPU_ENABLED}
CUDA_IMAGE=${CUDA_IMAGE}
NVIDIA_CONTAINER_TOOLKIT_VERSION=${NVIDIA_CONTAINER_TOOLKIT_VERSION}
STORAGE_ROOT=${storage_env}
EOF
    chmod 0600 "${STAGING_PATH}/.env"

    mkdir -p -- "${STAGING_PATH}/secrets"
    [[ -s "${STAGING_PATH}/secrets/ssh_authorized_keys" ]] ||
        die 'The staged SSH authorized-keys secret is missing.'
    printf '%s' "${PASSWORD_VALUE}" >"${STAGING_PATH}/secrets/login_password.txt"
    chmod 0600 "${STAGING_PATH}/secrets/login_password.txt"
    PASSWORD_VALUE=''

    TEMPLATE_TOKENS=(
        [ENVIRONMENT_NAME]="${ENVIRONMENT_NAME}"
        [ACCOUNT_NAME]="${ACCOUNT_NAME}"
        [HOST_ADDRESS]="${HOST_ADDRESS}"
        [SSH_PORT]="${SSH_PORT}"
        [RDP_PORT]="${RDP_PORT}"
        [RDP_FULL_ADDRESS]="${HOST_ADDRESS}:${RDP_PORT}"
        [LOCAL_RDP_FILE]="${local_rdp_file}"
        [REMOTE_RDP_FILE]="${remote_rdp_file}"
        [REMOTE_SUBNET]="${REMOTE_SUBNET}"
        [WIREGUARD_HUB_ENDPOINT]="${WIREGUARD_HUB_ENDPOINT}"
        [WIREGUARD_HUB_PUBLIC_KEY]="${WIREGUARD_HUB_PUBLIC_KEY}"
        [WIREGUARD_ADDRESS]="${WIREGUARD_ADDRESS}"
        [WIREGUARD_IP]="${WIREGUARD_IP}"
        [WIREGUARD_NETWORK]="${WIREGUARD_NETWORK}"
        [WIREGUARD_MTU]="${WIREGUARD_MTU}"
        [WIREGUARD_KEEPALIVE]="${WIREGUARD_KEEPALIVE}"
        [WIREGUARD_PUBLIC_KEY_FILE]="${wireguard_public_key_file}"
        [WIREGUARD_HUB_PEER_FILE]="${wireguard_hub_peer_file}"
        [WIREGUARD_STATE_VOLUME]="${wireguard_state_volume}"
        [SSH_PRIVATE_KEY]="${SSH_PRIVATE_KEY_FILE}"
        [SSH_PUBLIC_KEY]="${SSH_PUBLIC_KEY_FILE}"
        [SSH_FINGERPRINT]="${SSH_KEY_FINGERPRINT}"
        [STORAGE_ROOT]="${STORAGE_PATH}"
        [HOME_STORAGE]="${HOME_STORAGE_PATH}"
        [WORKSPACE_STORAGE]="${WORKSPACE_STORAGE_PATH}"
        [PROJECT_PATH]="${TARGET_PATH}"
        [PROJECT_PATH_SHELL]="$(single_quote_shell_value "${TARGET_PATH}")"
        [DESKTOP_CPUS]="${desktop_cpu_display}"
        [DESKTOP_MEMORY]="${desktop_memory_display}"
        [DIND_CPUS]="${dind_cpu_display}"
        [DIND_MEMORY]="${dind_memory_display}"
        [DESKTOP_CPU_LIMIT]="${desktop_cpu_limit}"
        [DESKTOP_MEMORY_LIMIT]="${desktop_memory_limit}"
        [DIND_CPU_LIMIT]="${dind_cpu_limit}"
        [DIND_MEMORY_LIMIT]="${dind_memory_limit}"
        [HOST_PLATFORM]='Ubuntu/Linux'
        [FIREWALL_COMMAND]="sudo $(single_quote_shell_value "${firewall_script}")"
        [FIREWALL_CHAIN]="${firewall_chain}"
        [GPU_STATUS]="${gpu_status}"
        [CUDA_IMAGE]="${CUDA_IMAGE}"
        [GPU_TEST_COMMAND]="${gpu_test_command}"
    )

    expand_template "${STAGING_PATH}/compose.yaml.template" "${STAGING_PATH}/compose.yaml"
    chmod 0644 "${STAGING_PATH}/compose.yaml"
    expand_template "${STAGING_PATH}/README.md.template" "${STAGING_PATH}/README.md"
    expand_template "${STAGING_PATH}/environment_VM.rdp.template" "${STAGING_PATH}/${local_rdp_file}"
    TEMPLATE_TOKENS[RDP_FULL_ADDRESS]="${WIREGUARD_IP}:3389"
    expand_template "${STAGING_PATH}/environment_VM.rdp.template" "${STAGING_PATH}/${remote_rdp_file}"
    TEMPLATE_TOKENS[RDP_FULL_ADDRESS]="${HOST_ADDRESS}:${RDP_PORT}"
    expand_template "${STAGING_PATH}/configure_firewall.sh.template" "${STAGING_PATH}/configure_${ENVIRONMENT_NAME_SNAKE}_firewall.sh"
    chmod 0755 "${STAGING_PATH}/configure_${ENVIRONMENT_NAME_SNAKE}_firewall.sh"

    expand_template "${STAGING_PATH}/test_gpu.sh.template" "${STAGING_PATH}/test_gpu.sh"
    chmod 0755 "${STAGING_PATH}/test_gpu.sh"
    if [[ "${GPU_ENABLED}" == 1 ]]; then
        expand_template "${STAGING_PATH}/compose.gpu.yaml.template" "${STAGING_PATH}/compose.override.yaml"
    fi

    rm -f -- \
        "${STAGING_PATH}/compose.yaml.template" \
        "${STAGING_PATH}/README.md.template" \
        "${STAGING_PATH}/environment_VM.rdp.template" \
        "${STAGING_PATH}/configure_firewall.sh.template" \
        "${STAGING_PATH}/ConfigureFirewall.ps1.template" \
        "${STAGING_PATH}/compose.gpu.yaml.template" \
        "${STAGING_PATH}/test_gpu.sh.template" \
        "${STAGING_PATH}/TestGpu.ps1.template"

    cat >"${STAGING_PATH}/.environment.json" <<EOF
{
  "schemaVersion": 3,
  "generator": "${SCRIPT_NAME}",
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostOs": "linux",
  "environmentName": "$(json_escape "${ENVIRONMENT_NAME}")",
  "projectName": "ubuntu-dind-$(json_escape "${ENVIRONMENT_NAME}")",
  "accountName": "$(json_escape "${ACCOUNT_NAME}")",
  "accountUid": ${ACCOUNT_UID},
  "accountGid": ${ACCOUNT_GID},
  "storagePath": "$(json_escape "${STORAGE_PATH}")",
  "hostAddress": "${HOST_ADDRESS}",
  "remoteSubnet": "${REMOTE_SUBNET}",
  "sshPort": ${SSH_PORT},
  "rdpPort": ${RDP_PORT},
  "sshAuthentication": "key-only",
  "sshPrivateKeyFile": "$(json_escape "${SSH_PRIVATE_KEY_FILE}")",
  "sshPublicKeyFile": "$(json_escape "${SSH_PUBLIC_KEY_FILE}")",
  "sshKeyFingerprint": "$(json_escape "${SSH_KEY_FINGERPRINT}")",
  "localRdpFile": "$(json_escape "${local_rdp_file}")",
  "remoteRdpFile": "$(json_escape "${remote_rdp_file}")",
  "hostPort3389Reserved": true,
  "wireguardRequired": true,
  "wireguardAddress": "${WIREGUARD_ADDRESS}",
  "wireguardIp": "${WIREGUARD_IP}",
  "wireguardNetwork": "${WIREGUARD_NETWORK}",
  "wireguardHubEndpoint": "$(json_escape "${WIREGUARD_HUB_ENDPOINT}")",
  "wireguardHubPublicKey": "${WIREGUARD_HUB_PUBLIC_KEY}",
  "wireguardMtu": ${WIREGUARD_MTU},
  "wireguardKeepalive": ${WIREGUARD_KEEPALIVE},
  "wireguardPublicKeyFile": "${wireguard_public_key_file}",
  "wireguardHubPeerFile": "${wireguard_hub_peer_file}",
  "wireguardStateVolume": "${wireguard_state_volume}",
  "wireguardKeyGeneratedOnFirstStart": true,
  "desktopCpus": ${DESKTOP_CPUS},
  "desktopCpusUnlimited": ${desktop_cpus_unlimited},
  "desktopMemory": "${DESKTOP_MEMORY}",
  "desktopMemoryUnlimited": ${desktop_memory_unlimited},
  "dindCpus": ${DIND_CPUS},
  "dindCpusUnlimited": ${dind_cpus_unlimited},
  "dindMemory": "${DIND_MEMORY}",
  "dindMemoryUnlimited": ${dind_memory_unlimited},
  "dockerVersion": "${DOCKER_VERSION}",
  "imageTag": "${image_tag}",
  "gpuMode": "${GPU_MODE}",
  "gpuEnabled": $([[ "${GPU_ENABLED}" == 1 ]] && printf true || printf false),
  "cudaImage": "$(json_escape "${CUDA_IMAGE}")",
  "nvidiaContainerToolkitVersion": "$(json_escape "${NVIDIA_CONTAINER_TOOLKIT_VERSION}")"
}
EOF
    chmod 0644 "${STAGING_PATH}/.environment.json" "${STAGING_PATH}/README.md" \
        "${STAGING_PATH}/${local_rdp_file}" "${STAGING_PATH}/${remote_rdp_file}"
}

decide_legacy_migration() {
    local legacy_volume="${ENVIRONMENT_NAME}_home"
    local marker="${HOME_STORAGE_PATH}/.legacy-volume-migrated"
    local has_data='0'
    LEGACY_MIGRATION_NEEDED='0'

    directory_has_entries "${HOME_STORAGE_PATH}" && has_data='1' || true
    if [[ -f "${marker}" ]]; then
        [[ "${MIGRATE_LEGACY_HOME}" != yes ]] || info 'Legacy home migration marker already exists; migration will not be repeated.'
        return 0
    fi

    if [[ "${MIGRATE_LEGACY_HOME}" == yes ]]; then
        docker_volume_exists "${legacy_volume}" || die "Legacy volume does not exist: ${legacy_volume}"
        [[ "${has_data}" == 0 ]] || die "Home storage is not empty; refusing legacy migration: ${HOME_STORAGE_PATH}"
        LEGACY_MIGRATION_NEEDED='1'
    elif [[ "${MIGRATE_LEGACY_HOME}" == auto ]] && docker_volume_exists "${legacy_volume}" && [[ "${has_data}" == 0 ]]; then
        if read_yes_no "Migrate legacy volume ${legacy_volume} into the host-mounted home?" 'Y'; then
            LEGACY_MIGRATION_NEEDED='1'
        else
            local answer_status=$?
            (( answer_status != 2 )) || warn 'Non-interactive run: legacy home migration was not selected.'
        fi
    fi

    if [[ "${LEGACY_MIGRATION_NEEDED}" == 1 ]] && ! docker_image_exists 'ubuntu:26.04'; then
        docker pull ubuntu:26.04
    fi
}

perform_legacy_migration() {
    local legacy_volume="${ENVIRONMENT_NAME}_home"
    info "Migrating ${legacy_volume} to ${HOME_STORAGE_PATH} ..."
    docker run --rm \
        --mount "type=volume,src=${legacy_volume},dst=/source,readonly" \
        --mount "type=bind,src=${HOME_STORAGE_PATH},dst=/destination" \
        ubuntu:26.04 \
        bash -Eeuo pipefail -c \
        'tar -C /source -cf - . | tar -C /destination --no-overwrite-dir -xpf -; touch /destination/.legacy-volume-migrated; chown "$1:$2" /destination/.legacy-volume-migrated' \
        _ "${ACCOUNT_UID}" "${ACCOUNT_GID}"
}

build_images() {
    info 'Building desktop, DinD, and WireGuard images ...'
    if [[ "${USE_BUILDKIT}" == 1 ]]; then
        (
            export DOCKER_BUILDKIT=1
            export COMPOSE_DOCKER_CLI_BUILD=1
            compose_in "${STAGING_PATH}" build desktop docker wireguard
        )
    else
        compose_in "${STAGING_PATH}" build desktop docker wireguard
    fi
}

main() {
    local old_env lock_path timestamp firewall_script compose_version_output engine_version_output

    parse_arguments "$@"

    for command_name in docker flock ip ss awk grep find stat realpath tar cksum nproc base64 wc tr ssh-keygen install mktemp; do
        command -v "${command_name}" >/dev/null 2>&1 || die "Required command is missing: ${command_name}"
    done
    docker info >/dev/null 2>&1 || die 'Docker Engine is unavailable or the current user cannot access it.'
    engine_version_output="$(docker version --format '{{.Server.Version}}' 2>/dev/null)" ||
        die 'Unable to query the Docker Engine server version; Docker Engine 28.0.0 or newer is required.'
    validate_docker_engine_version "${engine_version_output}" || die "${DOCKER_ENGINE_VERSION_ERROR}"
    if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q 'rootless'; then
        die 'Rootless Docker is not supported because the isolated DinD service requires privileged mode and overlay2.'
    fi
    compose_version_output="$(docker compose version --short 2>/dev/null)" ||
        die 'Unable to query Docker Compose with version --short; Docker Compose 2.33.1 or newer is required.'
    validate_docker_compose_version "${compose_version_output}" || die "${DOCKER_COMPOSE_VERSION_ERROR}"

    ROOT_PATH="$(realpath -m -- "${ROOT_PATH}")"
    validate_no_line_breaks 'Root path' "${ROOT_PATH}"
    mkdir -p -- "${ROOT_PATH}" "${ROOT_PATH}/.locks" "${ROOT_PATH}/.staging"
    TEMPLATE_PATH="${SCRIPT_DIRECTORY}/templates/ubuntu-dind"
    [[ -d "${TEMPLATE_PATH}" ]] || die "Template directory is missing: ${TEMPLATE_PATH}"

    lock_path="${ROOT_PATH}/.locks/ubuntu-dind-generator.lock"
    exec {GENERATOR_LOCK_FD}>"${lock_path}"
    flock -w 600 "${GENERATOR_LOCK_FD}" || die 'Another environment generation is still running.'

    if [[ -z "${ENVIRONMENT_NAME}" ]]; then
        is_interactive || die '--environment is required in non-interactive mode.'
        read -r -p 'Environment name: ' ENVIRONMENT_NAME
    fi
    ENVIRONMENT_NAME="${ENVIRONMENT_NAME,,}"
    (( ${#ENVIRONMENT_NAME} <= 32 )) &&
        [[ "${ENVIRONMENT_NAME}" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]] ||
        die 'Environment name must start with a lowercase letter and use single hyphens only between lowercase alphanumeric segments.'
    ENVIRONMENT_NAME_SNAKE="${ENVIRONMENT_NAME//-/_}"

    TARGET_PATH="${ROOT_PATH}/${ENVIRONMENT_NAME}"
    if [[ -e "${TARGET_PATH}" && ! -d "${TARGET_PATH}" ]]; then
        die "Environment target exists but is not a directory: ${TARGET_PATH}"
    fi
    [[ -d "${TARGET_PATH}" ]] && OLD_TARGET_EXISTED='1'
    old_env="${TARGET_PATH}/.env"

    STORAGE_PATH="${ROOT_PATH}/mount/${ENVIRONMENT_NAME}"
    HOME_STORAGE_PATH="${STORAGE_PATH}/home"
    WORKSPACE_STORAGE_PATH="${STORAGE_PATH}/workspace"
    if [[ ! -d "${HOME_STORAGE_PATH}" ]]; then
        mkdir -p -- "${HOME_STORAGE_PATH}"
        chmod 0750 "${HOME_STORAGE_PATH}"
    fi
    if [[ ! -d "${WORKSPACE_STORAGE_PATH}" ]]; then
        mkdir -p -- "${WORKSPACE_STORAGE_PATH}"
        chmod 0770 "${WORKSPACE_STORAGE_PATH}"
    fi

    prepare_inputs

    STAGING_PATH="${ROOT_PATH}/.staging/${ENVIRONMENT_NAME}.$(random_suffix)"
    mkdir -p -- "${STAGING_PATH}"
    cp -a -- "${TEMPLATE_PATH}/." "${STAGING_PATH}/"
    install -d -m 0700 "${STAGING_PATH}/wireguard"
    prepare_ssh_identity
    write_environment_files

    compose_in "${STAGING_PATH}" config --quiet
    if [[ "${GENERATE_ONLY}" == 1 ]]; then
        [[ "${OLD_TARGET_EXISTED}" != 1 ]] || die '--generate-only cannot replace an existing environment.'
        mv -- "${STAGING_PATH}" "${TARGET_PATH}"
        STAGING_PATH=''
        SWAPPED='1'
        COMPLETED='1'
        info "Environment configuration generated: ${TARGET_PATH}"
        info "SSH private key: ${TARGET_PATH}/${SSH_PRIVATE_KEY_FILE}"
        info "SSH public key: ${TARGET_PATH}/${SSH_PUBLIC_KEY_FILE} (${SSH_KEY_FINGERPRINT})"
        info "Local SSH after startup: ssh -o IdentitiesOnly=yes -i $(single_quote_shell_value "${TARGET_PATH}/${SSH_PRIVATE_KEY_FILE}") -p ${SSH_PORT} ${ACCOUNT_NAME}@${HOST_ADDRESS}"
        info "Remote SSH after Hub registration: ssh -o IdentitiesOnly=yes -i $(single_quote_shell_value "${TARGET_PATH}/${SSH_PRIVATE_KEY_FILE}") ${ACCOUNT_NAME}@${WIREGUARD_IP}"
        info "Local RDP file: ${TARGET_PATH}/${ENVIRONMENT_NAME}_local.rdp"
        info "Remote RDP file: ${TARGET_PATH}/${ENVIRONMENT_NAME}_remote.rdp"
        info 'The WireGuard public key and Hub peer snippet are generated on the first Compose start.'
        info "Start command: cd $(single_quote_shell_value "${TARGET_PATH}") && docker compose --env-file .env up -d --build"
        info "Copy public key: docker compose --env-file .env cp wireguard:/var/lib/wireguard/public.key wireguard/${ENVIRONMENT_NAME}_wireguard_public.key"
        info "Copy Hub peer: docker compose --env-file .env cp wireguard:/var/lib/wireguard/hub_peer.conf wireguard/${ENVIRONMENT_NAME}_hub_peer.conf"
        info "Expected Hub peer file: ${TARGET_PATH}/wireguard/${ENVIRONMENT_NAME}_hub_peer.conf"
        return 0
    fi

    build_images
    decide_legacy_migration

    if [[ "${OLD_TARGET_EXISTED}" == 1 ]]; then
        info "Stopping existing environment ${ENVIRONMENT_NAME} ..."
        OLD_STOPPED='1'
        compose_in "${TARGET_PATH}" down --remove-orphans
    fi

    if [[ "${LEGACY_MIGRATION_NEEDED}" == 1 ]]; then
        perform_legacy_migration
    fi

    if [[ "${OLD_TARGET_EXISTED}" == 1 ]]; then
        mkdir -p -- "${ROOT_PATH}/.backup"
        timestamp="$(date +%Y%m%d-%H%M%S)"
        BACKUP_PATH="${ROOT_PATH}/.backup/${ENVIRONMENT_NAME}.${timestamp}.$(random_suffix)"
        mv -- "${TARGET_PATH}" "${BACKUP_PATH}"
    fi

    mv -- "${STAGING_PATH}" "${TARGET_PATH}"
    STAGING_PATH=''
    SWAPPED='1'

    if [[ "${FIREWALL_MODE}" == apply ]]; then
        firewall_script="${TARGET_PATH}/configure_${ENVIRONMENT_NAME_SNAKE}_firewall.sh"
        apply_firewall "${firewall_script}"
    else
        warn "Firewall policy was generated but not applied. Run: sudo $(single_quote_shell_value "${TARGET_PATH}/configure_${ENVIRONMENT_NAME_SNAKE}_firewall.sh")"
    fi

    compose_in "${TARGET_PATH}" up -d
    NEW_STARTED='1'
    wait_until_healthy "${TARGET_PATH}"
    export_wireguard_outputs "${TARGET_PATH}"

    if [[ "${GPU_ENABLED}" == 1 ]]; then
        info 'Running direct and nested GPU verification ...'
        "${TARGET_PATH}/test_gpu.sh"
    fi

    COMPLETED='1'
    info ''
    info "Environment created: ${ENVIRONMENT_NAME}"
    info "Configuration: ${TARGET_PATH}"
    info "Persistent home: ${HOME_STORAGE_PATH}"
    info "Persistent workspace: ${WORKSPACE_STORAGE_PATH}"
    info "Local SSH: ssh -o IdentitiesOnly=yes -i $(single_quote_shell_value "${TARGET_PATH}/${SSH_PRIVATE_KEY_FILE}") -p ${SSH_PORT} ${ACCOUNT_NAME}@${HOST_ADDRESS}"
    info "Remote SSH: ssh -o IdentitiesOnly=yes -i $(single_quote_shell_value "${TARGET_PATH}/${SSH_PRIVATE_KEY_FILE}") ${ACCOUNT_NAME}@${WIREGUARD_IP}"
    info "SSH public key: ${TARGET_PATH}/${SSH_PUBLIC_KEY_FILE} (${SSH_KEY_FINGERPRINT})"
    info "Local RDP file: ${TARGET_PATH}/${ENVIRONMENT_NAME}_local.rdp"
    info "Remote RDP file: ${TARGET_PATH}/${ENVIRONMENT_NAME}_remote.rdp"
    info "WireGuard: ${WIREGUARD_ADDRESS} via ${WIREGUARD_HUB_ENDPOINT}"
    info "WireGuard public key: ${TARGET_PATH}/wireguard/${ENVIRONMENT_NAME}_wireguard_public.key"
    info "Hub peer config: ${TARGET_PATH}/wireguard/${ENVIRONMENT_NAME}_hub_peer.conf"
    info "Resources: desktop=$(resource_display_value "${DESKTOP_CPUS}") CPU/$(resource_display_value "${DESKTOP_MEMORY}"), DinD=$(resource_display_value "${DIND_CPUS}") CPU/$(resource_display_value "${DIND_MEMORY}")"
    info "GPU: $([[ "${GPU_ENABLED}" == 1 ]] && printf 'enabled (%s)' "${CUDA_IMAGE}" || printf 'disabled')"
    [[ -z "${BACKUP_PATH}" ]] || info "Previous configuration backup: ${BACKUP_PATH}"
}

trap on_error ERR
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
