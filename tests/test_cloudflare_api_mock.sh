#!/usr/bin/env bash
set -Eeuo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly generator="${repo_root}/new_ubuntu_dind_environment.sh"
readonly temporary_root="$(mktemp -d)"
readonly api_work_path="${temporary_root}/api"
readonly staging_path="${temporary_root}/staging"
readonly curl_arguments_file="${temporary_root}/curl-arguments.txt"
readonly curl_config_file="${temporary_root}/curl-config.txt"
readonly request_log="${temporary_root}/request-log.txt"
readonly rollback_log="${temporary_root}/rollback-log.txt"
readonly mock_management_token='CI_DUMMY_MANAGEMENT_TOKEN_0123456789'
readonly mock_runtime_token='CI.DUMMY.RUNTIME.TUNNEL.TOKEN.0123456789'
readonly mock_tunnel_id='11111111-2222-4333-8444-555555555555'
readonly mock_route_id='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'

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

assert_file_mode() {
    local expected="$1"
    local path="$2"
    local actual
    actual="$(stat -c '%a' "${path}")"
    [[ "${actual}" == "${expected}" ]] ||
        fail "${path#${temporary_root}/} mode is ${actual}, expected ${expected}"
}

command -v python3 >/dev/null 2>&1 || fail 'python3 is required'

# Load generator functions without running main, then discard generator traps so
# this test owns its isolated cleanup lifecycle.
# shellcheck disable=SC1090
source <(sed '/^main "\$@"$/d' "${generator}")
trap - ERR EXIT INT TERM
trap cleanup EXIT

mkdir -p -- "${api_work_path}" "${staging_path}/secrets"
chmod 0700 "${api_work_path}" "${staging_path}/secrets"

CLOUDFLARE_API_TOKEN="${mock_management_token}"
CLOUDFLARE_ACCOUNT_ID='0123456789abcdef0123456789abcdef'
CLOUDFLARE_API_WORK_PATH="${api_work_path}"
MOCK_CURL_STATUS='200'
MOCK_CURL_MESSAGE='request accepted'

# cloudflare_api_request must provide Authorization only through curl's stdin
# config. This mock records stdin and argv separately and never opens a socket.
curl() {
    local output_file=''
    local argument

    umask 077
    cat >"${curl_config_file}"
    : >"${curl_arguments_file}"
    while (($#)); do
        argument="$1"
        printf '%s\n' "${argument}" >>"${curl_arguments_file}"
        if [[ "${argument}" == --output ]]; then
            (($# >= 2)) || return 2
            output_file="$2"
            shift
            printf '%s\n' "$1" >>"${curl_arguments_file}"
        fi
        shift
    done
    [[ -n "${output_file}" ]] || return 2
    python3 - "${output_file}" "${MOCK_CURL_MESSAGE}" "${MOCK_CURL_STATUS}" <<'PY'
import json
import sys

path, message, status = sys.argv[1:]
success = status == "200"
with open(path, "w", encoding="utf-8") as stream:
    json.dump(
        {
            "success": success,
            "result": [],
            "errors": [] if success else [{"message": message}],
        },
        stream,
    )
PY
    printf '%s' "${MOCK_CURL_STATUS}"
}

raw_request_output="${temporary_root}/raw-request-output.txt"
cloudflare_api_request GET '/cfd_tunnel?is_deleted=false&per_page=1' \
    >"${raw_request_output}" 2>&1 || fail 'mocked Cloudflare API request failed'
grep -Fqx -- "header = \"Authorization: Bearer ${mock_management_token}\"" "${curl_config_file}" ||
    fail 'management token was not supplied through curl stdin config'
grep -Fqx -- '--config' "${curl_arguments_file}" || fail 'curl stdin config option is missing'
grep -Fqx -- '-' "${curl_arguments_file}" || fail 'curl config is not read from stdin'
grep -Fqx -- '--request' "${curl_arguments_file}" || fail 'curl request method option is missing'
grep -Fqx -- 'GET' "${curl_arguments_file}" || fail 'curl GET method is missing'
grep -Fqx -- \
    "https://api.cloudflare.com/client/v4/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?is_deleted=false&per_page=1" \
    "${curl_arguments_file}" || fail 'Cloudflare account-scoped API URL is wrong'
! grep -Fq -- "${mock_management_token}" "${curl_arguments_file}" ||
    fail 'management token leaked into curl argv'
! grep -Fq -- "${mock_management_token}" "${raw_request_output}" ||
    fail 'management token leaked into command output'
assert_file_mode 600 "${api_work_path}/response.json"

# Even a hostile API error body must not make the management token printable.
MOCK_CURL_STATUS='403'
MOCK_CURL_MESSAGE="rejected credential ${mock_management_token}"
if cloudflare_api_request GET '/teamnet/routes?is_deleted=false&per_page=1000' \
    >"${raw_request_output}" 2>&1; then
    fail 'mocked Cloudflare API error unexpectedly succeeded'
fi
[[ "${CLOUDFLARE_API_LAST_ERROR}" != *"${mock_management_token}"* ]] ||
    fail 'management token leaked into the API error message'
! grep -Fq -- "${mock_management_token}" "${raw_request_output}" ||
    fail 'management token leaked into API error output'

# Mock the provisioning transport to verify API order, request bodies, address
# allocation, and secret handling without reading the repository .env.
cloudflare_candidate_conflicts_with_generated_environment() { return 1; }
cloudflare_candidate_conflicts_with_host() { return 1; }
cloudflare_candidate_conflicts_with_account_route() { return 1; }
cloudflare_api_request() {
    local method="$1"
    local path="$2"
    local body_file="${3:-}"
    local response_file="${CLOUDFLARE_API_WORK_PATH}/response.json"

    printf '%s\t%s\n' "${method}" "${path}" >>"${request_log}"
    CLOUDFLARE_API_LAST_HTTP_STATUS='200'
    CLOUDFLARE_API_LAST_AMBIGUOUS='0'
    CLOUDFLARE_API_LAST_ERROR=''
    case "${method} ${path}" in
        GET\ /cfd_tunnel\?name=*)
            printf '%s\n' '{"success":true,"result":[]}' >"${response_file}"
            ;;
        'POST /cfd_tunnel')
            [[ -n "${body_file}" ]] || fail 'Tunnel creation body is missing'
            python3 - "${body_file}" "dockervm-${ENVIRONMENT_NAME}" <<'PY' ||
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    body = json.load(stream)
raise SystemExit(0 if body == {"name": sys.argv[2], "config_src": "cloudflare"} else 1)
PY
                fail 'Tunnel creation body is wrong'
            printf '{"success":true,"result":{"id":"%s"}}\n' \
                "${mock_tunnel_id}" >"${response_file}"
            ;;
        "GET /cfd_tunnel/${mock_tunnel_id}/token")
            printf '{"success":true,"result":"%s"}\n' \
                "${mock_runtime_token}" >"${response_file}"
            ;;
        GET\ /teamnet/routes\?*)
            printf '%s\n' '{"success":true,"result":[]}' >"${response_file}"
            ;;
        'POST /teamnet/routes')
            [[ -n "${body_file}" ]] || fail 'Private-route creation body is missing'
            python3 - "${body_file}" "${mock_tunnel_id}" <<'PY' ||
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    body = json.load(stream)
valid = (
    body.get("network") == "10.210.0.2/32"
    and body.get("tunnel_id") == sys.argv[2]
    and "DockerVM environment ci-cloudflare" in body.get("comment", "")
)
raise SystemExit(0 if valid else 1)
PY
                fail 'Private-route creation body is wrong'
            printf '{"success":true,"result":{"id":"%s"}}\n' \
                "${mock_route_id}" >"${response_file}"
            ;;
        *) fail "Unexpected mocked Cloudflare API call: ${method} ${path}" ;;
    esac
}

MOCK_CURL_STATUS='200'
MOCK_CURL_MESSAGE='request accepted'
ROOT_PATH="${temporary_root}/generated-root"
TARGET_PATH="${ROOT_PATH}/ci-cloudflare"
STAGING_PATH="${staging_path}"
REMOTE_SUBNET='192.0.2.0/24'
ENVIRONMENT_NAME='ci-cloudflare'
CLOUDFLARE_PRIVATE_CIDR='10.210.0.0/24'
CLOUDFLARE_PRIVATE_SUBNET=''
CLOUDFLARE_PRIVATE_IP=''
CLOUDFLARE_TUNNEL_NAME=''
CLOUDFLARE_TUNNEL_ID=''
CLOUDFLARE_ROUTE_ID=''
CLOUDFLARE_TUNNEL_CREATED='0'
CLOUDFLARE_ROUTE_CREATED='0'
CLOUDFLARE_ROUTES_SNAPSHOT="${api_work_path}/routes.json"
: >"${request_log}"

provision_cloudflare_remote_access

[[ "${CLOUDFLARE_PRIVATE_SUBNET}" == '10.210.0.0/29' ]] ||
    fail "unexpected Cloudflare Docker subnet: ${CLOUDFLARE_PRIVATE_SUBNET}"
[[ "${CLOUDFLARE_PRIVATE_IP}" == '10.210.0.2' ]] ||
    fail "unexpected Cloudflare private IP: ${CLOUDFLARE_PRIVATE_IP}"
[[ "${CLOUDFLARE_TUNNEL_ID}" == "${mock_tunnel_id}" ]] || fail 'Tunnel ID was not recorded'
[[ "${CLOUDFLARE_ROUTE_ID}" == "${mock_route_id}" ]] || fail 'Route ID was not recorded'
[[ "${CLOUDFLARE_TUNNEL_CREATED}" == 1 ]] || fail 'Tunnel creation flag was not set'
[[ "${CLOUDFLARE_ROUTE_CREATED}" == 1 ]] || fail 'Route creation flag was not set'
runtime_token_file="${staging_path}/${CLOUDFLARE_TUNNEL_TOKEN_FILE}"
[[ -f "${runtime_token_file}" ]] || fail 'Tunnel runtime-token secret is missing'
assert_file_mode 444 "${runtime_token_file}"
[[ "$(<"${runtime_token_file}")" == "${mock_runtime_token}" ]] ||
    fail 'Tunnel runtime-token secret has unexpected content'
! grep -R -Fq -- "${mock_management_token}" "${staging_path}" ||
    fail 'management API token leaked into generated files'
! grep -Fq -- "${mock_management_token}" "${request_log}" ||
    fail 'management API token leaked into the API call log'

mapfile -t api_calls <"${request_log}"
[[ ${#api_calls[@]} -eq 5 ]] || fail "expected 5 provisioning API calls, got ${#api_calls[@]}"
[[ "${api_calls[0]}" == $'GET\t/cfd_tunnel?name=dockervm-ci-cloudflare&is_deleted=false&per_page=100' ]] ||
    fail 'Tunnel-name preflight is not the first provisioning call'
[[ "${api_calls[1]}" == $'POST\t/cfd_tunnel' ]] ||
    fail 'Tunnel creation is not the second provisioning call'
[[ "${api_calls[2]}" == $'GET\t/cfd_tunnel/'"${mock_tunnel_id}"'/token' ]] ||
    fail 'Tunnel-token retrieval is not the third provisioning call'
[[ "${api_calls[3]}" == $'GET\t/teamnet/routes?is_deleted=false&per_page=1000' ]] ||
    fail 'Route-conflict refresh is not the fourth provisioning call'
[[ "${api_calls[4]}" == $'POST\t/teamnet/routes' ]] ||
    fail 'Private-route creation is not the final provisioning call'

# Rollback must remove the owned route before the owned Tunnel and must use IDs,
# never names. Override only the transport boundary for this ordering check.
cloudflare_api_request() {
    printf '%s\t%s\n' "$1" "$2" >>"${rollback_log}"
}
REMOTE_ACCESS_PROVIDER='cloudflare'
: >"${rollback_log}"
rollback_cloudflare_remote_access
mapfile -t rollback_calls <"${rollback_log}"
[[ ${#rollback_calls[@]} -eq 2 ]] || fail "expected 2 rollback calls, got ${#rollback_calls[@]}"
[[ "${rollback_calls[0]}" == $'DELETE\t/teamnet/routes/'"${mock_route_id}" ]] ||
    fail 'Rollback did not delete the route first by ID'
[[ "${rollback_calls[1]}" == $'DELETE\t/cfd_tunnel/'"${mock_tunnel_id}" ]] ||
    fail 'Rollback did not delete the Tunnel second by ID'

# A process can stop after the completed target is committed but before its API
# journal is removed. An exact schema-4 ownership manifest proves that the
# resources belong to the committed environment, so recovery removes only the
# stale local workspace and makes no Cloudflare request.
committed_root="${temporary_root}/committed-recovery"
committed_environment='ci-committed'
committed_workspace="${committed_root}/.staging/.cloudflare-api.committed"
committed_manifest="${committed_root}/${committed_environment}/.environment.json"
committed_api_log="${temporary_root}/committed-recovery-api.log"
mkdir -p -- "${committed_workspace}" "${committed_root}/${committed_environment}"
printf '%s\n' \
    'journalVersion=1' \
    "accountId=${CLOUDFLARE_ACCOUNT_ID}" \
    "environmentName=${committed_environment}" \
    "tunnelName=dockervm-${committed_environment}" \
    'tunnelCreationStarted=1' \
    "tunnelId=${mock_tunnel_id}" \
    'privateIp=10.210.0.2' \
    'dockerSubnet=10.210.0.0/29' \
    "routeId=${mock_route_id}" \
    >"${committed_workspace}/created-resources.journal"
printf '%s\n' \
    '{' \
    '  "schemaVersion": 4,' \
    '  "remoteAccessProvider": "cloudflare",' \
    "  \"environmentName\": \"${committed_environment}\"," \
    "  \"cloudflareAccountId\": \"${CLOUDFLARE_ACCOUNT_ID}\"," \
    "  \"cloudflareTunnelName\": \"dockervm-${committed_environment}\"," \
    "  \"cloudflareTunnelId\": \"${mock_tunnel_id}\"," \
    "  \"cloudflareRouteId\": \"${mock_route_id}\"," \
    '  "cloudflarePrivateIp": "10.210.0.2",' \
    '  "cloudflarePrivateCidr": "10.210.0.2/32",' \
    '  "cloudflareDockerSubnet": "10.210.0.0/29"' \
    '}' \
    >"${committed_manifest}"
: >"${committed_api_log}"
cloudflare_api_request() {
    printf '%s\t%s\n' "$1" "$2" >>"${committed_api_log}"
    return 1
}
ROOT_PATH="${committed_root}"
CLOUDFLARE_API_WORK_PATH=''
recover_stale_cloudflare_api_workspaces
[[ ! -e "${committed_workspace}" ]] ||
    fail 'Committed schema-4 environment left its stale API workspace behind'
[[ ! -s "${committed_api_log}" ]] ||
    fail 'Committed schema-4 journal caused an unnecessary Cloudflare API call'
[[ -f "${committed_manifest}" ]] || fail 'Committed environment manifest was removed during recovery'

# If the target manifest disagrees and live ownership cannot be verified, the
# journal is the only recovery evidence. Preserve it and never issue DELETE.
uncertain_root="${temporary_root}/uncertain-recovery"
uncertain_environment='ci-uncertain'
uncertain_workspace="${uncertain_root}/.staging/.cloudflare-api.uncertain"
uncertain_manifest="${uncertain_root}/${uncertain_environment}/.environment.json"
uncertain_api_log="${temporary_root}/uncertain-recovery-api.log"
uncertain_output="${temporary_root}/uncertain-recovery-output.log"
mkdir -p -- "${uncertain_workspace}" "${uncertain_root}/${uncertain_environment}"
printf '%s\n' \
    'journalVersion=1' \
    "accountId=${CLOUDFLARE_ACCOUNT_ID}" \
    "environmentName=${uncertain_environment}" \
    "tunnelName=dockervm-${uncertain_environment}" \
    'tunnelCreationStarted=1' \
    "tunnelId=${mock_tunnel_id}" \
    'privateIp=10.210.0.2' \
    'dockerSubnet=10.210.0.0/29' \
    "routeId=${mock_route_id}" \
    >"${uncertain_workspace}/created-resources.journal"
printf '%s\n' \
    '{' \
    '  "schemaVersion": 4,' \
    '  "remoteAccessProvider": "cloudflare",' \
    "  \"environmentName\": \"${uncertain_environment}\"," \
    "  \"cloudflareAccountId\": \"${CLOUDFLARE_ACCOUNT_ID}\"," \
    "  \"cloudflareTunnelName\": \"dockervm-${uncertain_environment}\"," \
    "  \"cloudflareTunnelId\": \"${mock_tunnel_id}\"," \
    '  "cloudflareRouteId": "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",' \
    '  "cloudflarePrivateIp": "10.210.0.2",' \
    '  "cloudflarePrivateCidr": "10.210.0.2/32",' \
    '  "cloudflareDockerSubnet": "10.210.0.0/29"' \
    '}' \
    >"${uncertain_manifest}"
: >"${uncertain_api_log}"
cloudflare_api_request() {
    printf '%s\t%s\n' "$1" "$2" >>"${uncertain_api_log}"
    CLOUDFLARE_API_LAST_HTTP_STATUS='503'
    CLOUDFLARE_API_LAST_ERROR='synthetic ownership verification failure'
    return 1
}
ROOT_PATH="${uncertain_root}"
CLOUDFLARE_API_WORK_PATH=''
if (recover_stale_cloudflare_api_workspaces) >"${uncertain_output}" 2>&1; then
    fail 'Uncertain Cloudflare ownership unexpectedly recovered successfully'
fi
[[ -f "${uncertain_workspace}/created-resources.journal" ]] ||
    fail 'Uncertain Cloudflare ownership did not preserve its recovery journal'
grep -Fqx -- $'GET\t/cfd_tunnel/'"${mock_tunnel_id}" "${uncertain_api_log}" ||
    fail 'Uncertain recovery did not attempt read-only Tunnel verification'
! grep -Fq -- $'DELETE\t' "${uncertain_api_log}" ||
    fail 'Uncertain Cloudflare ownership triggered a destructive API call'
! grep -Fq -- "${mock_management_token}" "${uncertain_output}" ||
    fail 'Management token leaked during uncertain ownership recovery'

printf 'Cloudflare API mock tests passed without network access or repository secrets.\n'
