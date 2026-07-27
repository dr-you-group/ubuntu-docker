#!/usr/bin/env bash
set -Eeuo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly source_generator="${repo_root}/new_ubuntu_dind_environment.sh"
readonly real_docker="$(command -v docker)"
readonly temporary_root="$(mktemp -d)"
readonly fixture_repo="${temporary_root}/fixture-repository"
readonly fake_bin="${temporary_root}/fake-bin"
readonly success_root="${temporary_root}/success-output"
readonly failure_root="${temporary_root}/failure-output"
readonly api_log="${temporary_root}/cloudflare-api.log"
readonly docker_log="${temporary_root}/docker.log"
readonly success_log="${temporary_root}/success.log"
readonly failure_log="${temporary_root}/failure.log"
readonly environment_name='ci-cloudflare'
readonly failure_environment_name='ci-cloudflare-rollback'
readonly account_name='ciuser'
readonly password_value='CI-only-password-2026!'
readonly management_token='CI_DUMMY_MANAGEMENT_TOKEN_0123456789'
readonly runtime_token='CI.DUMMY.RUNTIME.TUNNEL.TOKEN.0123456789'
readonly account_id='0123456789abcdef0123456789abcdef'
readonly tunnel_id='11111111-2222-4333-8444-555555555555'
readonly route_id='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
readonly private_pool='10.210.0.0/24'
readonly private_subnet='10.210.0.0/29'
readonly private_ip='10.210.0.2'

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

# The generator copy reads only this disposable fixture .env. The repository
# root .env is neither copied nor sourced by this test.
mkdir -p -- "${fixture_repo}" "${fake_bin}" "${success_root}" "${failure_root}"
cp -- "${source_generator}" "${fixture_repo}/new_ubuntu_dind_environment.sh"
cp -a -- "${repo_root}/templates" "${fixture_repo}/templates"
chmod 0755 "${fixture_repo}/new_ubuntu_dind_environment.sh"
install -m 0600 /dev/null "${fixture_repo}/.env"
printf '%s\n' \
    "CLOUDFLARE_API_TOKEN=${management_token}" \
    "CLOUDFLARE_ACCOUNT_ID=${account_id}" \
    'CLOUDFLARE_TEAM_NAME=ci-dockervm' \
    "CLOUDFLARE_PRIVATE_CIDR=${private_pool}" \
    >"${fixture_repo}/.env"

cat >"${fake_bin}/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' "$*" >>"${FAKE_DOCKER_LOG:?}"

case "${1:-}" in
    info)
        case "$*" in
            *'{{.NCPU}}|{{.MemTotal}}'*) printf '4|8589934592\n' ;;
            *'{{json .SecurityOptions}}'*) printf '["name=seccomp"]\n' ;;
            *'{{json .Runtimes}}'*) printf '{"runc":{"path":"runc"}}\n' ;;
        esac
        ;;
    version)
        printf '29.1.3\n'
        ;;
    compose)
        shift
        if [[ "${1:-}" == version ]]; then
            printf 'v2.40.0\n'
            exit 0
        fi
        if [[ "${1:-}" == --env-file ]]; then
            (($# >= 2)) || exit 64
            shift 2
        fi
        case "${1:-}" in
            config|build|up|down|logs) ;;
            ps)
                [[ "${2:-}" == -q && -n "${3:-}" ]] || exit 64
                printf 'fake-%s-id\n' "$3"
                ;;
            cp)
                # A Cloudflare environment must never execute the legacy
                # WireGuard key-export path.
                exit 65
                ;;
            *) exit 64 ;;
        esac
        ;;
    inspect)
        case "$*" in
            *'.State.Health'*|*'.State.Status'*) printf 'healthy\n' ;;
            *) exit 1 ;;
        esac
        ;;
    ps)
        # No pre-existing Compose containers own the requested ports.
        ;;
    network)
        case "${2:-}" in
            ls) ;;
            inspect) exit 1 ;;
            *) exit 64 ;;
        esac
        ;;
    volume|image)
        # No legacy volume or cached migration image exists.
        exit 1
        ;;
    *) exit 64 ;;
esac
FAKE_DOCKER
chmod 0755 "${fake_bin}/docker"

cat >"${fake_bin}/ip" <<'FAKE_IP'
#!/usr/bin/env bash
set -Eeuo pipefail

case "$*" in
    '-4 route show default')
        printf '%s\n' 'default via 192.0.2.1 dev eth0 src 192.0.2.10'
        ;;
    '-4 route show')
        printf '%s\n' 'default via 192.0.2.1 dev eth0 src 192.0.2.10'
        ;;
    '-o -4 addr show'* )
        printf '%s\n' '2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0'
        ;;
    *) exit 64 ;;
esac
FAKE_IP
chmod 0755 "${fake_bin}/ip"

cat >"${fake_bin}/ss" <<'FAKE_SS'
#!/usr/bin/env bash
set -Eeuo pipefail
# No host TCP ports are listening in this synthetic Docker boundary.
exit 0
FAKE_SS
chmod 0755 "${fake_bin}/ss"

cat >"${fake_bin}/flock" <<'FAKE_FLOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
# The test root is unique, so no competing generator can share this lock file.
exit 0
FAKE_FLOCK
chmod 0755 "${fake_bin}/flock"

cat >"${fake_bin}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -Eeuo pipefail

method=''
url=''
output_file=''
body_file=''
config_line="$(cat)"
expected_config="header = \"Authorization: Bearer ${FAKE_CLOUDFLARE_MANAGEMENT_TOKEN:?}\""
[[ "${config_line}" == "${expected_config}" ]] || exit 66

for argument in "$@"; do
    [[ "${argument}" != *"${FAKE_CLOUDFLARE_MANAGEMENT_TOKEN}"* ]] || exit 67
done
while (($#)); do
    case "$1" in
        --request) method="$2"; shift 2 ;;
        --url) url="$2"; shift 2 ;;
        --output) output_file="$2"; shift 2 ;;
        --data-binary) body_file="${2#@}"; shift 2 ;;
        --config|--connect-timeout|--max-time|--retry|--header|--write-out)
            shift 2
            ;;
        --retry-all-errors|--silent|--show-error) shift ;;
        *) exit 68 ;;
    esac
done

[[ -n "${method}" && -n "${url}" && -n "${output_file}" ]] || exit 69
prefix="https://api.cloudflare.com/client/v4/accounts/${FAKE_CLOUDFLARE_ACCOUNT_ID:?}"
[[ "${url}" == "${prefix}"/* ]] || exit 70
path="${url#${prefix}}"
printf '%s\t%s\n' "${method}" "${path}" >>"${FAKE_CLOUDFLARE_LOG:?}"

case "${method} ${path}" in
    GET\ /cfd_tunnel\?*)
        printf '%s\n' '{"success":true,"result":[]}' >"${output_file}"
        printf '200'
        ;;
    GET\ /teamnet/routes\?*)
        printf '%s\n' '{"success":true,"result":[]}' >"${output_file}"
        printf '200'
        ;;
    POST\ /cfd_tunnel)
        python3 - "${body_file}" <<'PY' || exit 71
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    body = json.load(stream)
valid = body.get("config_src") == "cloudflare" and body.get("name", "").startswith("dockervm-")
raise SystemExit(0 if valid else 1)
PY
        printf '{"success":true,"result":{"id":"%s"}}\n' \
            "${FAKE_CLOUDFLARE_TUNNEL_ID:?}" >"${output_file}"
        printf '200'
        ;;
    GET\ /cfd_tunnel/*/token)
        printf '{"success":true,"result":"%s"}\n' \
            "${FAKE_CLOUDFLARE_RUNTIME_TOKEN:?}" >"${output_file}"
        printf '200'
        ;;
    POST\ /teamnet/routes)
        python3 - \
            "${body_file}" \
            "${FAKE_CLOUDFLARE_PRIVATE_IP:?}/32" \
            "${FAKE_CLOUDFLARE_TUNNEL_ID:?}" <<'PY' || exit 72
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    body = json.load(stream)
valid = (
    body.get("network") == sys.argv[2]
    and body.get("tunnel_id") == sys.argv[3]
    and body.get("comment", "").startswith("DockerVM environment ")
)
raise SystemExit(0 if valid else 1)
PY
        if [[ "${FAKE_CLOUDFLARE_MODE:-success}" == route-failure ]]; then
            printf '%s\n' '{"success":false,"errors":[{"message":"synthetic route failure"}]}' \
                >"${output_file}"
            printf '500'
        else
            printf '{"success":true,"result":{"id":"%s"}}\n' \
                "${FAKE_CLOUDFLARE_ROUTE_ID:?}" >"${output_file}"
            printf '200'
        fi
        ;;
    DELETE\ /teamnet/routes/*|DELETE\ /cfd_tunnel/*)
        printf '%s\n' '{"success":true,"result":{}}' >"${output_file}"
        printf '200'
        ;;
    *) exit 73 ;;
esac
FAKE_CURL
chmod 0755 "${fake_bin}/curl"

readonly host_address='192.0.2.10'
readonly remote_subnet='192.0.2.0/24'
readonly ssh_port='49222'
readonly rdp_port='49390'

export FAKE_DOCKER_LOG="${docker_log}"
export FAKE_CLOUDFLARE_LOG="${api_log}"
export FAKE_CLOUDFLARE_MANAGEMENT_TOKEN="${management_token}"
export FAKE_CLOUDFLARE_RUNTIME_TOKEN="${runtime_token}"
export FAKE_CLOUDFLARE_ACCOUNT_ID="${account_id}"
export FAKE_CLOUDFLARE_TUNNEL_ID="${tunnel_id}"
export FAKE_CLOUDFLARE_ROUTE_ID="${route_id}"
export FAKE_CLOUDFLARE_PRIVATE_IP="${private_ip}"
export FAKE_CLOUDFLARE_MODE='success'
: >"${api_log}"
: >"${docker_log}"

if ! printf '%s\n' "${password_value}" | PATH="${fake_bin}:${PATH}" \
    "${fixture_repo}/new_ubuntu_dind_environment.sh" \
        --environment "${environment_name}" \
        --account "${account_name}" \
        --password-stdin \
        --uid 1001 \
        --gid 1001 \
        --root "${success_root}" \
        --host-address "${host_address}" \
        --remote-subnet "${remote_subnet}" \
        --ssh-port "${ssh_port}" \
        --rdp-port "${rdp_port}" \
        --remote-access-provider cloudflare \
        --desktop-cpus -1 \
        --desktop-memory -1 \
        --dind-cpus -1 \
        --dind-memory -1 \
        --docker-version 28.5.1 \
        --gpu off \
        --skip-firewall \
        >"${success_log}" 2>&1; then
    if grep -Fq -- "${management_token}" "${success_log}" ||
        grep -Fq -- "${runtime_token}" "${success_log}" ||
        grep -Fq -- "${password_value}" "${success_log}"; then
        fail 'Cloudflare generation failed and leaked a secret into its output'
    fi
    sed -n '1,160p' "${success_log}" >&2
    fail 'Cloudflare generation failed against the fake API'
fi

project_path="${success_root}/${environment_name}"
[[ -d "${project_path}" ]] || fail 'Cloudflare generator did not create the project directory'
[[ -f "${project_path}/${environment_name}_remote.rdp" ]] || fail 'Remote RDP file is missing'
[[ -f "${project_path}/secrets/cloudflared_tunnel_token" ]] ||
    fail 'cloudflared runtime-token secret is missing'
[[ "$(stat -c '%a' "${project_path}/secrets")" == 700 ]] ||
    fail 'generated secrets directory mode is not 700'
[[ "$(stat -c '%a' "${project_path}/secrets/cloudflared_tunnel_token")" == 444 ]] ||
    fail 'cloudflared runtime-token secret mode is not 444'
[[ "$(<"${project_path}/secrets/cloudflared_tunnel_token")" == "${runtime_token}" ]] ||
    fail 'cloudflared runtime-token secret has unexpected content'

tr -d '\r' <"${project_path}/${environment_name}_remote.rdp" |
    grep -Fqx -- "full address:s:${private_ip}:3389" || fail 'Cloudflare remote RDP target is wrong'

if grep -R -I -E '__[A-Z][A-Z0-9_]*__' "${project_path}" >/dev/null; then
    fail 'Generated Cloudflare project contains unresolved template tokens'
fi
! grep -R -Fq -- "${management_token}" "${project_path}" ||
    fail 'management API token leaked into the generated project'
! grep -Fq -- "${management_token}" "${success_log}" ||
    fail 'management API token leaked into generator output'
! grep -Fq -- "${management_token}" "${api_log}" ||
    fail 'management API token leaked into the fake API log'

mapfile -t runtime_token_locations < <(grep -R -l -F -- "${runtime_token}" "${project_path}" || true)
[[ ${#runtime_token_locations[@]} -eq 1 ]] ||
    fail 'Tunnel runtime token appears outside its single secret file'
[[ "${runtime_token_locations[0]}" == "${project_path}/secrets/cloudflared_tunnel_token" ]] ||
    fail 'Tunnel runtime token appears in an unexpected file'

(
    cd -- "${project_path}"
    "${real_docker}" compose --env-file .env config --quiet
    "${real_docker}" compose --env-file .env config --format json >"${temporary_root}/cloudflare-compose.json"
)

python3 - \
    "${temporary_root}/cloudflare-compose.json" \
    "${project_path}/.environment.json" \
    "${private_ip}" \
    "${private_subnet}" \
    "${tunnel_id}" \
    "${route_id}" <<'PY'
import json
import sys

compose_path, metadata_path, private_ip, private_subnet, tunnel_id, route_id = sys.argv[1:]
with open(compose_path, encoding="utf-8") as stream:
    compose = json.load(stream)
with open(metadata_path, encoding="utf-8") as stream:
    metadata = json.load(stream)

services = compose["services"]
assert set(services) == {"desktop", "docker", "cloudflared"}
cloudflared = services["cloudflared"]
assert cloudflared["image"].startswith("cloudflare/cloudflared:")
assert "@sha256:" in cloudflared["image"]
assert cloudflared["command"][-2:] == ["--token-file", "/run/secrets/cloudflared_token"]
assert cloudflared["cap_drop"] == ["ALL"]
assert cloudflared["read_only"] is True
assert cloudflared["security_opt"] == ["no-new-privileges:true"]
assert "cap_add" not in cloudflared
assert "devices" not in cloudflared
assert not cloudflared.get("privileged", False)
assert cloudflared["networks"]["cloudflare_egress"]["gw_priority"] == 1
assert services["desktop"]["networks"]["remote_access"]["ipv4_address"] == private_ip
assert compose["networks"]["remote_access"]["internal"] is True
assert compose["networks"]["remote_access"]["ipam"]["config"][0]["subnet"] == private_subnet
assert compose["secrets"]["cloudflared_token"]["file"].endswith(
    "/secrets/cloudflared_tunnel_token"
)

serialized = json.dumps(compose)
for forbidden in ("CLOUDFLARE_API_TOKEN", "/dev/net/tun", "NET_ADMIN"):
    assert forbidden not in serialized

assert metadata["schemaVersion"] == 4
assert metadata["remoteAccessProvider"] == "cloudflare"
assert metadata["cloudflarePrivateIp"] == private_ip
assert metadata["cloudflareDockerSubnet"] == private_subnet
assert metadata["cloudflareTunnelId"] == tunnel_id
assert metadata["cloudflareRouteId"] == route_id
assert "cloudflareApiToken" not in metadata
assert "cloudflareTunnelToken" not in metadata
PY

mapfile -t success_api_calls <"${api_log}"
[[ ${#success_api_calls[@]} -eq 7 ]] ||
    fail "expected 7 successful-generation API calls, got ${#success_api_calls[@]}"
[[ "${success_api_calls[0]}" == $'GET\t/cfd_tunnel?is_deleted=false&per_page=1' ]] ||
    fail 'Tunnel permission check was not first'
[[ "${success_api_calls[1]}" == $'GET\t/teamnet/routes?is_deleted=false&per_page=1000' ]] ||
    fail 'Route permission check was not second'
[[ "${success_api_calls[2]}" == $'GET\t/cfd_tunnel?name=dockervm-ci-cloudflare&is_deleted=false&per_page=100' ]] ||
    fail 'Tunnel-name preflight was not third'
[[ "${success_api_calls[3]}" == $'POST\t/cfd_tunnel' ]] || fail 'Tunnel was not created fourth'
[[ "${success_api_calls[4]}" == $'GET\t/cfd_tunnel/'"${tunnel_id}"'/token' ]] ||
    fail 'Tunnel token was not retrieved fifth'
[[ "${success_api_calls[5]}" == $'GET\t/teamnet/routes?is_deleted=false&per_page=1000' ]] ||
    fail 'Route-conflict refresh was not sixth'
[[ "${success_api_calls[6]}" == $'POST\t/teamnet/routes' ]] ||
    fail 'Private route was not created last'

# A route-creation failure occurs after the Tunnel and runtime token exist. The
# transaction must delete the newly owned Tunnel and leave no generated target.
export FAKE_CLOUDFLARE_MODE='route-failure'
: >"${api_log}"
if printf '%s\n' "${password_value}" | PATH="${fake_bin}:${PATH}" \
    "${fixture_repo}/new_ubuntu_dind_environment.sh" \
    --environment "${failure_environment_name}" \
    --account "${account_name}" \
    --password-stdin \
    --uid 1001 \
    --gid 1001 \
    --root "${failure_root}" \
    --host-address "${host_address}" \
    --remote-subnet "${remote_subnet}" \
    --ssh-port "${ssh_port}" \
    --rdp-port "${rdp_port}" \
    --remote-access-provider cloudflare \
    --desktop-cpus -1 \
    --desktop-memory -1 \
    --dind-cpus -1 \
    --dind-memory -1 \
    --docker-version 28.5.1 \
    --gpu off \
    --skip-firewall \
    >"${failure_log}" 2>&1; then
    fail 'Synthetic Cloudflare route failure unexpectedly succeeded'
fi

[[ ! -e "${failure_root}/${failure_environment_name}" ]] ||
    fail 'Failed Cloudflare transaction left a generated target directory'
! grep -R -Fq -- "${runtime_token}" "${failure_root}" ||
    fail 'Failed Cloudflare transaction left a runtime token on disk'
! grep -Fq -- "${management_token}" "${failure_log}" ||
    fail 'Management API token leaked into failure output'
! grep -Fq -- "${management_token}" "${api_log}" ||
    fail 'Management API token leaked into the rollback API log'

mapfile -t failure_api_calls <"${api_log}"
[[ ${#failure_api_calls[@]} -eq 9 ]] ||
    fail "expected 9 route-failure API calls, got ${#failure_api_calls[@]}"
[[ "${failure_api_calls[6]}" == $'POST\t/teamnet/routes' ]] ||
    fail 'Synthetic failure did not occur while creating the private route'
[[ "${failure_api_calls[7]}" == $'GET\t/teamnet/routes?is_deleted=false&per_page=1000' ]] ||
    fail 'Ambiguous route creation was not reconciled before rollback'
[[ "${failure_api_calls[8]}" == $'DELETE\t/cfd_tunnel/'"${tunnel_id}" ]] ||
    fail 'Failed route transaction did not delete its Tunnel by ID'
for call in "${failure_api_calls[@]}"; do
    [[ "${call}" != $'DELETE\t/teamnet/routes/'* ]] ||
        fail 'Rollback tried to delete a route that Cloudflare never created'
done

printf 'Cloudflare generator smoke and transactional rollback tests passed.\n'
