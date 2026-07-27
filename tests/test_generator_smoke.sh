#!/usr/bin/env bash
set -Eeuo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly real_docker="$(command -v docker)"
readonly temporary_root="$(mktemp -d)"
readonly fake_bin="${temporary_root}/fake-bin"
readonly output_root="${temporary_root}/output"
readonly environment_name='ci-environment'
readonly account_name='ciuser'
readonly password_value='CI-only-password-2026!'
readonly wireguard_ip='10.253.77.10'
readonly wireguard_address="${wireguard_ip}/24"
readonly hub_public_key='eym0tv2TMkozjekoJ6d25eVR2zl+gYgZswk/2EtzIhU='
readonly project_path="${output_root}/${environment_name}"

cleanup() {
    case "${temporary_root}" in
        /tmp/*|/private/tmp/*) rm -rf -- "${temporary_root}" ;;
        *) printf 'Refusing to remove unexpected temporary path: %s\n' "${temporary_root}" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

command -v python3 >/dev/null 2>&1 || fail 'python3 is required'
"${real_docker}" compose version >/dev/null 2>&1 || fail 'Docker Compose is required'

host_address="$(ip -o -4 address show scope global | awk 'NR == 1 { split($4, value, "/"); print value[1] }')"
[[ -n "${host_address}" ]] || fail 'Could not detect a global IPv4 address'
readonly host_address
readonly remote_subnet="${host_address}/32"

ssh_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("0.0.0.0", 0))
    print(sock.getsockname()[1])
PY
)"
rdp_port="$(python3 - <<'PY'
import socket
while True:
    with socket.socket() as sock:
        sock.bind(("0.0.0.0", 0))
        port = sock.getsockname()[1]
    if port >= 3390:
        print(port)
        break
PY
)"
readonly ssh_port rdp_port
[[ "${ssh_port}" != "${rdp_port}" ]] || fail 'Test ports unexpectedly match'

mkdir -p -- "${fake_bin}"
cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    info)
        case "$*" in
            *'{{.NCPU}}|{{.MemTotal}}'*) printf '4|8589934592\n' ;;
            *'{{json .SecurityOptions}}'*) printf '["name=seccomp"]\n' ;;
        esac
        ;;
    version)
        printf '29.1.3\n'
        ;;
    compose)
        if [[ "${2:-}" == version ]]; then
            printf 'v2.40.0\n'
        fi
        ;;
esac
EOF
chmod 0755 "${fake_bin}/docker"

printf '%s\n' "${password_value}" | PATH="${fake_bin}:${PATH}" \
    "${repo_root}/new_ubuntu_dind_environment.sh" \
    --environment "${environment_name}" \
    --account "${account_name}" \
    --password-stdin \
    --uid 1001 \
    --gid 1001 \
    --root "${output_root}" \
    --host-address "${host_address}" \
    --remote-subnet "${remote_subnet}" \
    --ssh-port "${ssh_port}" \
    --rdp-port "${rdp_port}" \
    --wireguard-hub-endpoint '192.0.2.1:51820' \
    --wireguard-hub-public-key "${hub_public_key}" \
    --wireguard-address "${wireguard_address}" \
    --wireguard-mtu 1380 \
    --wireguard-keepalive 25 \
    --desktop-cpus -1 \
    --desktop-memory -1 \
    --dind-cpus -1 \
    --dind-memory -1 \
    --docker-version 28.5.1 \
    --gpu off \
    --generate-only \
    --skip-firewall

[[ -d "${project_path}" ]] || fail 'Generator did not create the project directory'
[[ -f "${project_path}/${environment_name}_local.rdp" ]] || fail 'Local RDP file is missing'
[[ -f "${project_path}/${environment_name}_remote.rdp" ]] || fail 'Remote RDP file is missing'
[[ -f "${project_path}/${environment_name}_ssh.pem" ]] || fail 'SSH private key is missing'
[[ -f "${project_path}/${environment_name}_ssh.pub" ]] || fail 'SSH public key is missing'

asserted_private_mode="$(stat -c '%a' "${project_path}/${environment_name}_ssh.pem")"
[[ "${asserted_private_mode}" == 600 ]] || fail "SSH private-key mode is ${asserted_private_mode}, expected 600"
head -n 1 "${project_path}/${environment_name}_ssh.pem" |
    grep -Fqx -- '-----BEGIN RSA PRIVATE KEY-----' || fail 'SSH key is not RSA PEM'

derived_public="$(ssh-keygen -y -P '' -f "${project_path}/${environment_name}_ssh.pem")"
stored_public="$(awk 'NF { print $1 " " $2; exit }' "${project_path}/${environment_name}_ssh.pub")"
authorized_public="$(awk 'NF { print $1 " " $2; exit }' "${project_path}/secrets/ssh_authorized_keys")"
[[ "${derived_public}" == "${stored_public}" ]] || fail 'SSH public key does not match private key'
[[ "${derived_public}" == "${authorized_public}" ]] || fail 'authorized_keys does not match private key'

tr -d '\r' <"${project_path}/${environment_name}_local.rdp" |
    grep -Fqx -- "full address:s:${host_address}:${rdp_port}" || fail 'Local RDP target is wrong'
tr -d '\r' <"${project_path}/${environment_name}_remote.rdp" |
    grep -Fqx -- "full address:s:${wireguard_ip}:3389" || fail 'Remote RDP target is wrong'

if grep -R -I -E '__[A-Z][A-Z0-9_]*__' "${project_path}" >/dev/null; then
    fail 'Generated project contains unresolved template tokens'
fi
if grep -Fq -- '-----BEGIN RSA PRIVATE KEY-----' \
    "${project_path}/.env" "${project_path}/compose.yaml" "${project_path}/README.md"; then
    fail 'SSH private key leaked into generated configuration'
fi

mapfile -t password_locations < <(grep -R -l -F -- "${password_value}" "${project_path}" || true)
[[ ${#password_locations[@]} -eq 1 ]] || fail 'Password appears outside its single secret file'
[[ "${password_locations[0]}" == "${project_path}/secrets/login_password.txt" ]] ||
    fail 'Password appears in an unexpected file'

(
    cd -- "${project_path}"
    "${real_docker}" compose --env-file .env config --quiet
    "${real_docker}" compose --env-file .env config --services >"${temporary_root}/services.txt"
    "${real_docker}" compose --env-file .env config --format json >"${temporary_root}/compose.json"
)

python3 - "${temporary_root}/compose.json" "${project_path}/.environment.json" \
    "${ssh_port}" "${rdp_port}" <<'PY'
import json
import sys

compose_path, metadata_path, ssh_port, rdp_port = sys.argv[1:]
with open(compose_path, encoding="utf-8") as stream:
    compose = json.load(stream)
with open(metadata_path, encoding="utf-8") as stream:
    metadata = json.load(stream)

services = compose["services"]
assert set(services) == {"desktop", "docker", "wireguard", "remote_proxy"}
assert services["remote_proxy"]["network_mode"] == "service:wireguard"
assert services["wireguard"]["cap_add"] == ["NET_ADMIN"]
assert services["remote_proxy"]["cap_add"] == ["NET_BIND_SERVICE"]
assert compose["networks"]["remote_access"]["internal"] is True
assert services["wireguard"]["networks"]["wireguard_transport"]["gw_priority"] == 1
assert services["desktop"]["networks"]["environment"]["gw_priority"] == 1

for service_name in ("desktop", "docker"):
    assert "cpus" not in services[service_name]
    assert "mem_limit" not in services[service_name]

published = [str(item["published"]) for item in services["desktop"]["ports"]]
assert ssh_port in published
assert rdp_port in published
assert "3389" not in published
assert "ports" not in services["docker"]

assert metadata["schemaVersion"] == 3
assert metadata["sshAuthentication"] == "key-only"
assert metadata["hostPort3389Reserved"] is True
assert metadata["wireguardIp"] == "10.253.77.10"
assert metadata["desktopCpusUnlimited"] is True
assert metadata["desktopMemoryUnlimited"] is True
assert metadata["dindCpusUnlimited"] is True
assert metadata["dindMemoryUnlimited"] is True
PY

mapfile -t services <"${temporary_root}/services.txt"
[[ " ${services[*]} " == *' desktop '* ]] || fail 'desktop service missing'
[[ " ${services[*]} " == *' docker '* ]] || fail 'docker service missing'
[[ " ${services[*]} " == *' wireguard '* ]] || fail 'wireguard service missing'
[[ " ${services[*]} " == *' remote_proxy '* ]] || fail 'remote_proxy service missing'

printf 'Linux generator and Compose smoke test passed.\n'
