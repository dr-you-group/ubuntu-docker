#!/usr/bin/env bash
set -Eeuo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly generator="${repo_root}/new_ubuntu_dind_environment.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    [[ "${actual}" == "${expected}" ]] ||
        fail "${label}: expected '${expected}', got '${actual}'"
}

assert_file_contains() {
    local path="$1"
    local value="$2"
    grep -Fqx -- "${value}" "${path}" || fail "Missing '${value}' in ${path#${repo_root}/}"
}

assert_file_not_contains() {
    local path="$1"
    local value="$2"
    ! grep -Fq -- "${value}" "${path}" || fail "Forbidden '${value}' in ${path#${repo_root}/}"
}

expect_success() {
    local label="$1"
    shift
    "$@" || fail "Expected success: ${label}"
}

expect_failure() {
    local label="$1"
    shift
    if "$@"; then
        fail "Expected failure: ${label}"
    fi
}

mapfile -t shell_files < <(
    find "${repo_root}" -maxdepth 1 -type f -name '*.sh' -print
    find "${repo_root}/templates/ubuntu-dind" -maxdepth 1 -type f \
        \( -name '*.sh' -o -name '*.sh.template' \) -print
    find "${repo_root}/tests" -maxdepth 1 -type f -name '*.sh' -print
)

for path in "${shell_files[@]}"; do
    if head -n 1 "${path}" | grep -q 'bash'; then
        bash -n "${path}"
    else
        sh -n "${path}"
    fi
    if grep -Iq . "${path}" && grep -q $'\r' "${path}"; then
        fail "Shell file contains CRLF: ${path#${repo_root}/}"
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    bash_files=()
    sh_files=()
    for path in "${shell_files[@]}"; do
        if head -n 1 "${path}" | grep -q 'bash'; then
            bash_files+=("${path}")
        else
            sh_files+=("${path}")
        fi
    done
    ((${#bash_files[@]} == 0)) || shellcheck --severity=error --shell=bash "${bash_files[@]}"
    ((${#sh_files[@]} == 0)) || shellcheck --severity=error --shell=sh "${sh_files[@]}"
fi

# Load pure generator helpers without executing main or retaining its traps.
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "${generator}")
trap - ERR EXIT INT TERM

expect_success 'Engine 28 boundary' validate_docker_engine_version '28.0.0'
expect_success 'Engine metadata' validate_docker_engine_version 'v29.1.3+desktop.1'
expect_failure 'Engine 27 rejected' validate_docker_engine_version '27.5.1'
expect_failure 'Malformed Engine version rejected' validate_docker_engine_version '28.0'

expect_success 'Compose 2.33.1 boundary' validate_docker_compose_version '2.33.1'
expect_success 'Compose metadata' validate_docker_compose_version 'v2.40.0-desktop.1'
expect_failure 'Compose 2.33.0 rejected' validate_docker_compose_version '2.33.0'

expect_success 'IPv4 WireGuard endpoint' validate_wireguard_endpoint '192.0.2.1:51820'
expect_success 'DNS WireGuard endpoint' validate_wireguard_endpoint 'wg.example.com:51820'
expect_failure 'IPv6 endpoint rejected' validate_wireguard_endpoint '[2001:db8::1]:51820'
expect_failure 'Invalid IPv4 endpoint rejected' validate_wireguard_endpoint '999.0.2.1:51820'
expect_failure 'Port zero rejected' validate_wireguard_endpoint 'wg.example.com:0'

readonly valid_public_key='eym0tv2TMkozjekoJ6d25eVR2zl+gYgZswk/2EtzIhU='
expect_success 'WireGuard public key' validate_wireguard_public_key "${valid_public_key}"
expect_failure 'All-zero WireGuard key rejected' \
    validate_wireguard_public_key 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
expect_failure 'Malformed WireGuard key rejected' validate_wireguard_public_key 'not-a-key'

expect_success 'Usable WireGuard host address' validate_wireguard_address '10.253.77.10/24'
expect_failure 'WireGuard network address rejected' validate_wireguard_address '10.253.77.0/24'
expect_failure 'WireGuard broadcast rejected' validate_wireguard_address '10.253.77.255/24'
expect_failure 'WireGuard /30 rejected' validate_wireguard_address '10.253.77.10/30'
assert_equal '10.200.0.10/24' "$(canonicalize_wireguard_address '010.200.000.010/24')" \
    'WireGuard address canonicalization'

expect_success 'Overlapping CIDRs detected' cidr_ranges_overlap '10.0.0.0/24' '10.0.0.128/25'
expect_failure 'Separate CIDRs remain separate' cidr_ranges_overlap '10.0.0.0/24' '10.0.1.0/24'

expect_success 'Unlimited CPU accepted' validate_cpu_value '-1'
expect_success 'Quarter CPU accepted' validate_cpu_value '0.25'
expect_failure 'Zero CPU rejected' validate_cpu_value '0'
expect_failure 'Negative CPU rejected' validate_cpu_value '-2'
assert_equal '-1' "$(normalise_memory_value '-1')" 'Unlimited memory normalization'
assert_equal '4g' "$(normalise_memory_value '4G')" 'Memory normalization'
expect_failure 'Unitless memory rejected' normalise_memory_value '4096'

readonly ssh_config="${repo_root}/templates/ubuntu-dind/ssh-container.conf"
assert_file_contains "${ssh_config}" 'PubkeyAuthentication yes'
assert_file_contains "${ssh_config}" 'PasswordAuthentication no'
assert_file_contains "${ssh_config}" 'KbdInteractiveAuthentication no'
assert_file_contains "${ssh_config}" 'AuthenticationMethods publickey'
assert_file_contains "${ssh_config}" 'PermitRootLogin no'
assert_file_not_contains "${ssh_config}" 'PasswordAuthentication yes'

readonly compose_template="${repo_root}/templates/ubuntu-dind/compose.yaml.template"
grep -Fq -- '"${HOST_ADDRESS}:${RDP_PORT}:3389"' "${compose_template}" ||
    fail 'LAN RDP mapping is missing'
grep -Fq -- 'network_mode: service:wireguard' "${compose_template}" ||
    fail 'Remote proxy does not share the WireGuard namespace'
grep -Fq -- '/dev/net/tun:/dev/net/tun' "${compose_template}" ||
    fail 'WireGuard TUN device mapping is missing'
grep -Fq -- 'internal: true' "${compose_template}" ||
    fail 'Remote-access network is not internal'
! grep -Fq -- '"${HOST_ADDRESS}:3389:3389"' "${compose_template}" ||
    fail 'Reserved host port 3389 is published'

wireguard_block="$(sed -n '/^  wireguard:/,/^  remote_proxy:/p' "${compose_template}")"
[[ "${wireguard_block}" != *'privileged: true'* ]] || fail 'WireGuard service is privileged'
[[ "${wireguard_block}" == *'- NET_ADMIN'* ]] || fail 'WireGuard service lacks NET_ADMIN'
proxy_block="$(sed -n '/^  remote_proxy:/,/^secrets:/p' "${compose_template}")"
[[ "${proxy_block}" == *'- NET_BIND_SERVICE'* ]] || fail 'Remote proxy lacks NET_BIND_SERVICE'
[[ "${proxy_block}" != *'/var/lib/wireguard'* ]] || fail 'Remote proxy mounts WireGuard state'

assert_file_contains "${repo_root}/.gitignore" '!/.github/'
assert_file_contains "${repo_root}/.gitignore" '!/tests/'

while IFS= read -r tracked_path; do
    case "${tracked_path}" in
        *.pem|*.key|*.p12|*.pfx|*.rdp|*/secrets/*|*/wireguard/private.key)
            fail "Sensitive generated path is tracked: ${tracked_path}"
            ;;
    esac
done < <(git -C "${repo_root}" ls-files)

printf 'Linux static and unit tests passed.\n'
