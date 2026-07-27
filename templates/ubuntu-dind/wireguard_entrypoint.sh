#!/bin/sh
set -eu

umask 077

readonly environment_name="${ENVIRONMENT_NAME:?ENVIRONMENT_NAME is required}"
readonly wireguard_address="${WIREGUARD_ADDRESS:?WIREGUARD_ADDRESS is required}"
readonly wireguard_network="${WIREGUARD_NETWORK:?WIREGUARD_NETWORK is required}"
readonly hub_endpoint="${WIREGUARD_HUB_ENDPOINT:?WIREGUARD_HUB_ENDPOINT is required}"
readonly hub_public_key="${WIREGUARD_HUB_PUBLIC_KEY:?WIREGUARD_HUB_PUBLIC_KEY is required}"
readonly wireguard_mtu="${WIREGUARD_MTU:-1380}"
readonly keepalive="${WIREGUARD_KEEPALIVE:-25}"
readonly wireguard_ip="${wireguard_address%/*}"
readonly state_directory=/var/lib/wireguard
readonly private_key_file="${state_directory}/private.key"
readonly public_key_file="${state_directory}/public.key"
readonly configuration_file=/etc/wireguard/wg0.conf
readonly hub_peer_output="${state_directory}/hub_peer.conf"

case "${environment_name}" in
    *[!a-z0-9-]*|'')
        printf 'ERROR: invalid environment name\n' >&2
        exit 1
        ;;
esac
case "${wireguard_address}" in
    *[!0-9./]*|''|*/*/*)
        printf 'ERROR: invalid WireGuard address\n' >&2
        exit 1
        ;;
esac
case "${wireguard_network}" in
    *[!0-9./]*|''|*/*/*)
        printf 'ERROR: invalid WireGuard network\n' >&2
        exit 1
        ;;
esac
wireguard_prefix="${wireguard_address##*/}"
network_prefix="${wireguard_network##*/}"
case "${wireguard_prefix}:${network_prefix}" in
    *[!0-9:]*|:*|*:)
        printf 'ERROR: invalid WireGuard CIDR prefix\n' >&2
        exit 1
        ;;
esac
if [ "${wireguard_prefix}" -lt 8 ] || [ "${wireguard_prefix}" -gt 29 ] \
    || [ "${network_prefix}" != "${wireguard_prefix}" ]; then
    printf 'ERROR: WireGuard address and network must use the same /8 through /29 prefix\n' >&2
    exit 1
fi
if ! printf '%s\n' "${hub_endpoint}" \
    | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]{1,5}$'; then
    printf 'ERROR: invalid WireGuard Hub endpoint\n' >&2
    exit 1
fi
hub_port="${hub_endpoint##*:}"
if [ "${hub_port}" -lt 1 ] || [ "${hub_port}" -gt 65535 ]; then
    printf 'ERROR: invalid WireGuard Hub UDP port\n' >&2
    exit 1
fi
case "${hub_public_key}" in
    *[!A-Za-z0-9+/=]*|'')
        printf 'ERROR: invalid WireGuard Hub public key\n' >&2
        exit 1
        ;;
esac
decoded_key_size="$(printf '%s' "${hub_public_key}" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
if [ "${decoded_key_size}" != 32 ]; then
    printf 'ERROR: WireGuard Hub public key must decode to 32 bytes\n' >&2
    exit 1
fi
if [ "${hub_public_key}" = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' ]; then
    printf 'ERROR: WireGuard Hub public key must not be the all-zero key\n' >&2
    exit 1
fi
case "${wireguard_mtu}" in
    *[!0-9]*|'')
        printf 'ERROR: invalid WireGuard MTU\n' >&2
        exit 1
        ;;
esac
case "${keepalive}" in
    *[!0-9]*|'')
        printf 'ERROR: invalid WireGuard keepalive\n' >&2
        exit 1
        ;;
esac
if [ "${wireguard_mtu}" -lt 1280 ] || [ "${wireguard_mtu}" -gt 1420 ]; then
    printf 'ERROR: WireGuard MTU must be between 1280 and 1420\n' >&2
    exit 1
fi
if [ "${keepalive}" -lt 0 ] || [ "${keepalive}" -gt 65535 ]; then
    printf 'ERROR: WireGuard keepalive must be between 0 and 65535 seconds\n' >&2
    exit 1
fi

mkdir -p "${state_directory}" /etc/wireguard /run
chmod 0700 "${state_directory}" /etc/wireguard
chmod 0755 /run

if [ ! -s "${private_key_file}" ]; then
    temporary_private_key="${state_directory}/.private.key.$$"
    wg genkey >"${temporary_private_key}"
    chmod 0600 "${temporary_private_key}"
    mv -f "${temporary_private_key}" "${private_key_file}"
fi

temporary_public_key="${state_directory}/.public.key.$$"
if ! wg pubkey <"${private_key_file}" >"${temporary_public_key}"; then
    rm -f "${temporary_public_key}"
    printf 'ERROR: the persistent WireGuard private key is invalid\n' >&2
    exit 1
fi
chmod 0644 "${temporary_public_key}"
mv -f "${temporary_public_key}" "${public_key_file}"

private_key="$(cat "${private_key_file}")"
cat >"${configuration_file}" <<EOF
[Interface]
Address = ${wireguard_address}
PrivateKey = ${private_key}
MTU = ${wireguard_mtu}

[Peer]
PublicKey = ${hub_public_key}
Endpoint = ${hub_endpoint}
AllowedIPs = ${wireguard_network}
PersistentKeepalive = ${keepalive}
EOF
unset private_key
chmod 0600 "${configuration_file}"

temporary_peer="${state_directory}/.hub_peer.conf.$$"
cat >"${temporary_peer}" <<EOF
# Add this peer to the public WireGuard Hub, then reload the Hub configuration.
[Peer]
# DockerVM environment: ${environment_name}
PublicKey = $(cat "${public_key_file}")
AllowedIPs = ${wireguard_ip}/32
EOF
chmod 0644 "${temporary_peer}"
mv -f "${temporary_peer}" "${hub_peer_output}"

wg-quick up wg0

cleanup() {
    trap - INT TERM EXIT
    wg-quick down wg0 >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

printf 'WireGuard transport is ready for %s on %s.\n' \
    "${environment_name}" "${wireguard_ip}"

while wg show wg0 >/dev/null 2>&1; do
    sleep 5
done

printf 'ERROR: the WireGuard interface stopped unexpectedly\n' >&2
exit 1
