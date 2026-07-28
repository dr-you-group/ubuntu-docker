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
expect_success 'RFC1918 Cloudflare pool accepted' validate_private_ipv4_cidr '10.210.0.0/24'
expect_failure 'Public Cloudflare pool rejected' validate_private_ipv4_cidr '203.0.113.0/24'
expect_success 'Cloudflare Tunnel UUID accepted' \
    validate_cloudflare_identifier '11111111-2222-4333-8444-555555555555'
expect_failure 'Malformed Cloudflare resource ID rejected' \
    validate_cloudflare_identifier 'not-a-cloudflare-id'

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

readonly desktop_entrypoint="${repo_root}/templates/ubuntu-dind/docker_entrypoint.sh"
assert_file_contains "${desktop_entrypoint}" '    chmod 0777 "${account_home}" /workspace'
assert_file_contains "${desktop_entrypoint}" '    chown "${account_uid}:${account_gid}" "${account_home}" /workspace'
assert_file_contains "${desktop_entrypoint}" '    "${account_home}/.docker" \'
assert_file_contains "${desktop_entrypoint}" 'for writable_path in "${account_home}" "${account_home}/.docker" /workspace; do'
assert_file_contains "${desktop_entrypoint}" '    if ! runuser -u "${account_name}" -- test -w "${writable_path}"; then'
home_initialization_line="$(grep -n -F -- '    cp -a --update=none /etc/skel/. "${account_home}/"' "${desktop_entrypoint}" | cut -d: -f1)"
home_permission_line="$(grep -n -F -- '    chown "${account_uid}:${account_gid}" "${account_home}" /workspace' "${desktop_entrypoint}" | cut -d: -f1 | tail -n 1)"
writable_check_line="$(grep -n -F -- 'for writable_path in "${account_home}" "${account_home}/.docker" /workspace; do' "${desktop_entrypoint}" | cut -d: -f1)"
[[ "${home_initialization_line}" =~ ^[0-9]+$ && "${home_permission_line}" =~ ^[0-9]+$ && "${writable_check_line}" =~ ^[0-9]+$ ]] ||
    fail 'Could not locate desktop home initialization permission checks'
(( home_initialization_line < home_permission_line && home_permission_line < writable_check_line )) ||
    fail 'Desktop home permissions must be restored after skeleton initialization and before writability checks'

readonly xrdp_startwm="${repo_root}/templates/ubuntu-dind/xrdp_startwm.sh"
assert_file_contains "${xrdp_startwm}" 'export LANG="${LANG:-en_US.UTF-8}"'

readonly xrdp_korean_keyboard_setup="${repo_root}/templates/ubuntu-dind/configure_xrdp_korean_keyboard.sh"
grep -Fq -- 's/^Key109=.*/Key109=65332:0/' "${xrdp_korean_keyboard_setup}" ||
    fail 'XRDP Korean setup does not map right Control to Hangul_Hanja'
grep -Fq -- 's/^Key113=.*/Key113=65329:0/' "${xrdp_korean_keyboard_setup}" ||
    fail 'XRDP Korean setup does not map right Alt to Hangul'
for required_setting in \
    'rdp_layout_kr_hangul=0xe0010412' \
    'rdp_layout_kr_hangul=kr' \
    'keyboard_type=8' \
    'keyboard_subtype=1' \
    'model=pc105' \
    'variant=kr106' \
    'options=korean:ralt_hangul,korean:rctrl_hanja' \
    'rdp_layouts=rdp_layouts_kr_hangul' \
    'layouts_map=layouts_map_kr_hangul'; do
    assert_file_contains "${xrdp_korean_keyboard_setup}" "${required_setting}"
done

readonly desktop_dockerfile="${repo_root}/templates/ubuntu-dind/Dockerfile"
assert_file_contains "${desktop_dockerfile}" 'COPY configure_xrdp_korean_keyboard.sh /usr/local/sbin/configure_xrdp_korean_keyboard.sh'
assert_file_contains "${desktop_dockerfile}" '    && /usr/local/sbin/configure_xrdp_korean_keyboard.sh'
assert_file_contains "${desktop_dockerfile}" '        fonts-noto-color-emoji \'
assert_file_contains "${desktop_dockerfile}" '        fonts-powerline \'
assert_file_contains "${desktop_dockerfile}" '    && update-locale LANG=en_US.UTF-8 \'
assert_file_contains "${desktop_dockerfile}" "    && grep -Fqx 'LANG=en_US.UTF-8' /etc/default/locale \\"
grep -Fq -- ':charset=1F680' "${desktop_dockerfile}" ||
    fail 'Desktop image does not verify emoji glyph coverage'
grep -Fq -- ':charset=E0A0' "${desktop_dockerfile}" ||
    fail 'Desktop image does not verify Powerline glyph coverage'
assert_file_contains "${desktop_dockerfile}" 'RUN if getent passwd ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi \'
assert_file_contains "${desktop_dockerfile}" '    && if getent group ubuntu >/dev/null 2>&1; then groupdel ubuntu; fi'
ubuntu_cleanup_line="$(grep -n -F -- 'userdel --remove ubuntu' "${desktop_dockerfile}" | cut -d: -f1)"
account_creation_line="$(grep -n -F -- 'groupadd --gid "${ACCOUNT_GID}"' "${desktop_dockerfile}" | cut -d: -f1)"
[[ "${ubuntu_cleanup_line}" =~ ^[0-9]+$ && "${account_creation_line}" =~ ^[0-9]+$ ]] ||
    fail 'Could not locate the Ubuntu account cleanup and generated account creation steps'
(( ubuntu_cleanup_line < account_creation_line )) ||
    fail 'Ubuntu UID/GID 1000 must be released before the generated account is created'

readonly compose_template="${repo_root}/templates/ubuntu-dind/compose.yaml.template"
grep -Fq -- '"${HOST_ADDRESS}:${RDP_PORT}:3389"' "${compose_template}" ||
    fail 'LAN RDP mapping is missing'
! grep -Fq -- '"${HOST_ADDRESS}:3389:3389"' "${compose_template}" ||
    fail 'Reserved host port 3389 is published'
for token in \
    '__DESKTOP_REMOTE_NETWORKS__' \
    '__REMOTE_ACCESS_SERVICES__' \
    '__REMOTE_ACCESS_SECRETS__' \
    '__REMOTE_ACCESS_VOLUMES__' \
    '__REMOTE_ACCESS_NETWORKS__'; do
    grep -Fq -- "${token}" "${compose_template}" ||
        fail "Provider template slot is missing: ${token}"
done

readonly cloudflare_fragment="${repo_root}/templates/ubuntu-dind/compose.cloudflare.services.template"
[[ -f "${cloudflare_fragment}" ]] || fail 'Cloudflare Compose service fragment is missing'
grep -Eq -- '^    image: cloudflare/cloudflared:[^[:space:]@]+@sha256:[0-9a-f]{64}$' \
    "${cloudflare_fragment}" || fail 'cloudflared image is not pinned by tag and SHA-256 digest'
grep -Fqx -- '      - --token-file' "${cloudflare_fragment}" ||
    fail 'cloudflared does not use --token-file'
grep -Fqx -- '      - /run/secrets/cloudflared_token' "${cloudflare_fragment}" ||
    fail 'cloudflared token-file path is missing'
grep -Fqx -- '    cap_drop:' "${cloudflare_fragment}" ||
    fail 'cloudflared cap_drop is missing'
grep -Fqx -- '      - ALL' "${cloudflare_fragment}" ||
    fail 'cloudflared does not drop all capabilities'
grep -Fqx -- '    read_only: true' "${cloudflare_fragment}" ||
    fail 'cloudflared root filesystem is not read-only'
for forbidden in '/dev/net/tun' 'NET_ADMIN' 'privileged:' 'CLOUDFLARE_API_TOKEN'; do
    ! grep -Fq -- "${forbidden}" "${cloudflare_fragment}" ||
        fail "Cloudflare fragment contains forbidden runtime setting: ${forbidden}"
done
grep -Fq -- 'cloudflared_token' "${cloudflare_fragment}" ||
    fail 'Cloudflare fragment does not mount the tunnel-specific runtime secret'

readonly wireguard_fragment="${repo_root}/templates/ubuntu-dind/compose.wireguard.services.template"
[[ -f "${wireguard_fragment}" ]] || fail 'WireGuard Compose service fragment is missing'
grep -Fq -- 'network_mode: service:wireguard' "${wireguard_fragment}" ||
    fail 'Remote proxy does not share the WireGuard namespace'
grep -Fq -- '/dev/net/tun:/dev/net/tun' "${wireguard_fragment}" ||
    fail 'WireGuard TUN device mapping is missing'
wireguard_block="$(sed -n '/^  wireguard:/,/^  remote_proxy:/p' "${wireguard_fragment}")"
[[ "${wireguard_block}" != *'privileged: true'* ]] || fail 'WireGuard service is privileged'
[[ "${wireguard_block}" == *'- NET_ADMIN'* ]] || fail 'WireGuard service lacks NET_ADMIN'
proxy_block="$(sed -n '/^  remote_proxy:/,$p' "${wireguard_fragment}")"
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

bash "${repo_root}/tests/test_xrdp_korean_keyboard.sh"

printf 'Linux static and unit tests passed.\n'
