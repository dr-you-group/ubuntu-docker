#!/bin/sh
set -eu

umask 077

readonly wireguard_address="${WIREGUARD_ADDRESS:?WIREGUARD_ADDRESS is required}"
readonly wireguard_ip="${wireguard_address%/*}"
readonly ssh_target="${SSH_TARGET:-desktop:22}"
readonly rdp_target="${RDP_TARGET:-desktop:3389}"

case "${wireguard_address}" in
    *[!0-9./]*|''|*/*/*)
        printf 'ERROR: invalid WireGuard address\n' >&2
        exit 1
        ;;
esac
case "${ssh_target}:${rdp_target}" in
    *[!A-Za-z0-9.:-]*)
        printf 'ERROR: invalid remote proxy target\n' >&2
        exit 1
        ;;
esac

mkdir -p /run
chmod 0755 /run
if [ ! -d /sys/class/net/wg0 ]; then
    printf 'ERROR: the shared WireGuard interface is unavailable\n' >&2
    exit 1
fi

cleanup() {
    trap - INT TERM EXIT
    if [ -s /run/ssh_proxy.pid ]; then
        kill "$(cat /run/ssh_proxy.pid)" 2>/dev/null || true
    fi
    if [ -s /run/rdp_proxy.pid ]; then
        kill "$(cat /run/rdp_proxy.pid)" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

socat "TCP4-LISTEN:22,bind=${wireguard_ip},reuseaddr,fork" "TCP4:${ssh_target}" &
printf '%s\n' "$!" >/run/ssh_proxy.pid
socat "TCP4-LISTEN:3389,bind=${wireguard_ip},reuseaddr,fork" "TCP4:${rdp_target}" &
printf '%s\n' "$!" >/run/rdp_proxy.pid

printf 'WireGuard SSH and RDP proxies are ready on %s.\n' "${wireguard_ip}"

while kill -0 "$(cat /run/ssh_proxy.pid)" 2>/dev/null \
    && kill -0 "$(cat /run/rdp_proxy.pid)" 2>/dev/null; do
    sleep 5
done

printf 'ERROR: an SSH or RDP proxy stopped unexpectedly\n' >&2
exit 1
