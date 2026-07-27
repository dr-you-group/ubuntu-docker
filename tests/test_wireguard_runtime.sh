#!/usr/bin/env bash
set -Eeuo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly suffix="${RANDOM}-$$"
readonly prefix="ubuntu-docker-ci-${suffix}"
readonly image="${prefix}:local"
readonly desktop_container="${prefix}-desktop"
readonly wireguard_container="${prefix}-wireguard"
readonly proxy_container="${prefix}-proxy"
readonly transport_network="${prefix}-transport"
readonly remote_network="${prefix}-remote"
readonly state_volume="${prefix}-state"
readonly wireguard_ip='10.254.77.10'
readonly wireguard_address="${wireguard_ip}/24"
readonly wireguard_network='10.254.77.0/24'

cleanup() {
    docker rm -f \
        "${proxy_container}" "${wireguard_container}" "${desktop_container}" \
        >/dev/null 2>&1 || true
    docker network rm "${remote_network}" "${transport_network}" >/dev/null 2>&1 || true
    docker volume rm "${state_volume}" >/dev/null 2>&1 || true
    docker image rm "${image}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

docker info >/dev/null 2>&1 || fail 'Docker Engine is unavailable'
engine_version="$(docker version --format '{{.Server.Version}}')"
engine_major="${engine_version#v}"
engine_major="${engine_major%%.*}"
[[ "${engine_major}" =~ ^[0-9]+$ ]] || fail "Cannot parse Docker Engine version: ${engine_version}"
((engine_major >= 28)) || fail "Docker Engine 28 or newer is required, found ${engine_version}"

if [[ ! -c /dev/net/tun ]] && command -v sudo >/dev/null 2>&1; then
    sudo modprobe tun 2>/dev/null || true
    sudo install -d -m 0755 /dev/net
    [[ -e /dev/net/tun ]] || sudo mknod /dev/net/tun c 10 200
    sudo chmod 0666 /dev/net/tun
fi
[[ -c /dev/net/tun ]] || fail '/dev/net/tun is unavailable'

docker build \
    --tag "${image}" \
    --file "${repo_root}/templates/ubuntu-dind/Dockerfile.wireguard" \
    "${repo_root}/templates/ubuntu-dind"

docker run --rm --entrypoint /bin/sh "${image}" -c \
    'sh -n /usr/local/sbin/wireguard_entrypoint.sh /usr/local/sbin/remote_proxy_entrypoint.sh /usr/local/sbin/remote_proxy_healthcheck.sh'

hub_public_key="$(docker run --rm --entrypoint /bin/sh "${image}" -c 'wg genkey | wg pubkey')"
[[ "${hub_public_key}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail 'Could not generate a Hub public key'

docker network create "${transport_network}" >/dev/null
docker network create --internal "${remote_network}" >/dev/null
docker volume create "${state_volume}" >/dev/null

docker run -d \
    --name "${desktop_container}" \
    --network "${remote_network}" \
    --network-alias desktop \
    --entrypoint /bin/sh \
    "${image}" -c \
    'socat TCP4-LISTEN:22,reuseaddr,fork EXEC:/bin/cat & socat TCP4-LISTEN:3389,reuseaddr,fork EXEC:/bin/cat & wait' \
    >/dev/null

docker run -d \
    --name "${wireguard_container}" \
    --hostname ci-wireguard \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --device /dev/net/tun:/dev/net/tun \
    --security-opt no-new-privileges:true \
    --read-only \
    --tmpfs /etc/wireguard:rw,noexec,nosuid,size=1m,mode=0700 \
    --tmpfs /run:rw,nosuid,size=1m,mode=0755 \
    --tmpfs /tmp:rw,nosuid,size=1m,mode=1777 \
    --mount "type=volume,source=${state_volume},target=/var/lib/wireguard" \
    --network "name=${transport_network},gw-priority=1" \
    --env ENVIRONMENT_NAME=ci-environment \
    --env WIREGUARD_ADDRESS="${wireguard_address}" \
    --env WIREGUARD_NETWORK="${wireguard_network}" \
    --env WIREGUARD_HUB_ENDPOINT=192.0.2.1:51820 \
    --env WIREGUARD_HUB_PUBLIC_KEY="${hub_public_key}" \
    --env WIREGUARD_MTU=1380 \
    --env WIREGUARD_KEEPALIVE=25 \
    "${image}" >/dev/null

docker network connect "${remote_network}" "${wireguard_container}"

wireguard_ready='0'
for _ in $(seq 1 30); do
    if docker exec "${wireguard_container}" wg show wg0 >/dev/null 2>&1 &&
        docker exec "${wireguard_container}" test -s /var/lib/wireguard/public.key &&
        docker exec "${wireguard_container}" test -s /var/lib/wireguard/hub_peer.conf; then
        wireguard_ready='1'
        break
    fi
    sleep 1
done
if [[ "${wireguard_ready}" != 1 ]]; then
    docker logs "${wireguard_container}" >&2 || true
    fail 'WireGuard transport did not become ready'
fi

transport_gateway="$(docker network inspect --format '{{(index .IPAM.Config 0).Gateway}}' "${transport_network}")"
default_route="$(docker exec "${wireguard_container}" ip route show default)"
[[ "${default_route}" == *"via ${transport_gateway}"* ]] ||
    fail "WireGuard default route does not use the transport network: ${default_route}"

docker run -d \
    --name "${proxy_container}" \
    --network "container:${wireguard_container}" \
    --cap-drop ALL \
    --cap-add NET_BIND_SERVICE \
    --security-opt no-new-privileges:true \
    --read-only \
    --tmpfs /run:rw,nosuid,size=1m,mode=0755 \
    --tmpfs /tmp:rw,nosuid,size=1m,mode=1777 \
    --env WIREGUARD_ADDRESS="${wireguard_address}" \
    --env SSH_TARGET=desktop:22 \
    --env RDP_TARGET=desktop:3389 \
    --entrypoint /usr/local/sbin/remote_proxy_entrypoint.sh \
    "${image}" >/dev/null

proxy_ready='0'
for _ in $(seq 1 30); do
    if docker exec "${proxy_container}" /usr/local/sbin/remote_proxy_healthcheck.sh >/dev/null 2>&1; then
        proxy_ready='1'
        break
    fi
    sleep 1
done
if [[ "${proxy_ready}" != 1 ]]; then
    docker logs "${proxy_container}" >&2 || true
    fail 'WireGuard SSH/RDP proxy did not become ready'
fi

capabilities="$(docker exec "${proxy_container}" awk '/^CapEff:/ { print $2 }' /proc/1/status)"
[[ "${capabilities}" == '0000000000000400' ]] ||
    fail "Proxy has unexpected effective capabilities: ${capabilities}"
docker exec "${proxy_container}" test ! -e /var/lib/wireguard/private.key ||
    fail 'Proxy can see the WireGuard private key'

ssh_echo="$(printf 'ssh-proxy-ok' | docker exec -i "${proxy_container}" \
    socat - "TCP4:${wireguard_ip}:22,connect-timeout=5")"
rdp_echo="$(printf 'rdp-proxy-ok' | docker exec -i "${proxy_container}" \
    socat - "TCP4:${wireguard_ip}:3389,connect-timeout=5")"
[[ "${ssh_echo}" == 'ssh-proxy-ok' ]] || fail 'SSH proxy did not reach the desktop target'
[[ "${rdp_echo}" == 'rdp-proxy-ok' ]] || fail 'RDP proxy did not reach the desktop target'

public_key="$(docker exec "${wireguard_container}" cat /var/lib/wireguard/public.key)"
[[ "${public_key}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail 'WireGuard public output is invalid'
if docker exec "${wireguard_container}" grep -q '^PrivateKey' /var/lib/wireguard/hub_peer.conf; then
    fail 'Hub peer output exposes a private key'
fi

printf 'WireGuard sidecar runtime test passed.\n'
