#!/bin/sh
set -eu

readonly wireguard_address="${WIREGUARD_ADDRESS:?WIREGUARD_ADDRESS is required}"
readonly wireguard_ip="${wireguard_address%/*}"

test -d /sys/class/net/wg0
test -s /run/ssh_proxy.pid
kill -0 "$(cat /run/ssh_proxy.pid)"
test -s /run/rdp_proxy.pid
kill -0 "$(cat /run/rdp_proxy.pid)"

for port in 22 3389; do
    ss -H -ltn "sport = :${port}" \
        | awk -v expected="${wireguard_ip}:${port}" \
            '$4 == expected { found = 1 } END { exit(found ? 0 : 1) }'
done
