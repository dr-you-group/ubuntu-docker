#!/usr/bin/env bash
set -Eeuo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly desktop_entrypoint="${repo_root}/templates/ubuntu-dind/docker_entrypoint.sh"
readonly ubuntu_image='ubuntu:26.04'
readonly host_uid="$(id -u)"
readonly host_gid="$(id -g)"
test_root="$(mktemp -d /tmp/ubuntu-docker-home-permissions.XXXXXXXX)"

cleanup() {
    case "${test_root}" in
        /tmp/ubuntu-docker-home-permissions.*) ;;
        *) return ;;
    esac
    if [[ -d "${test_root}" ]]; then
        docker run --rm \
            --mount "type=bind,src=${test_root},dst=/fixture" \
            "${ubuntu_image}" chown -hR "${host_uid}:${host_gid}" /fixture \
            >/dev/null 2>&1 || true
        rm -rf -- "${test_root}"
    fi
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || {
    printf 'FAIL: docker is required for the desktop home permission test\n' >&2
    exit 1
}
docker info >/dev/null 2>&1 || {
    printf 'FAIL: the Docker Engine is unavailable\n' >&2
    exit 1
}

for platform in linux windows; do
    home_path="${test_root}/${platform}-home"
    workspace_path="${test_root}/${platform}-workspace"
    install -d -m 0700 "${home_path}" "${workspace_path}"

    docker run --rm --interactive \
        --env "TEST_HOST_PLATFORM=${platform}" \
        --mount "type=bind,src=${desktop_entrypoint},dst=/test/docker_entrypoint.sh,readonly" \
        --mount "type=bind,src=${home_path},dst=/home/permission-test" \
        --mount "type=bind,src=${workspace_path},dst=/workspace" \
        "${ubuntu_image}" bash -Eeuo pipefail -s <<'CONTAINER_TEST'
readonly account_name='permission-test'
readonly account_home="/home/${account_name}"
readonly account_uid='2000'
readonly account_gid='2000'
readonly host_platform="${TEST_HOST_PLATFORM}"
readonly setup_script='/tmp/persistent-bind-storage.sh'

groupadd --gid "${account_gid}" "${account_name}"
useradd --no-create-home --home-dir "${account_home}" --shell /bin/bash \
    --uid "${account_uid}" --gid "${account_gid}" "${account_name}"

sed -n \
    '/^# BEGIN persistent-bind-storage$/,/^# END persistent-bind-storage$/p' \
    /test/docker_entrypoint.sh > "${setup_script}"
[[ "$(grep -c '^# BEGIN persistent-bind-storage$' "${setup_script}")" == 1 ]]
[[ "$(grep -c '^# END persistent-bind-storage$' "${setup_script}")" == 1 ]]

assert_stat() {
    local path="$1"
    local field="$2"
    local expected="$3"
    local actual
    actual="$(stat -c "${field}" "${path}")"
    [[ "${actual}" == "${expected}" ]] || {
        printf 'FAIL: %s %s expected %s, got %s\n' \
            "${host_platform}" "${path}" "${expected}" "${actual}" >&2
        exit 1
    }
}

run_setup() {
    # shellcheck disable=SC1090
    source "${setup_script}"
}

assert_common_state() {
    assert_stat "${account_home}/.docker" '%u:%g' "${account_uid}:${account_gid}"
    assert_stat "${account_home}/.docker" '%a' '700'
    assert_stat "${account_home}/.docker/dind-certs" '%u:%g' "${account_uid}:${account_gid}"
    assert_stat "${account_home}/.docker/dind-certs" '%a' '700'
    assert_stat "${account_home}/.docker-vm-home-initialized" '%u:%g' \
        "${account_uid}:${account_gid}"
    assert_stat "${account_home}/.bashrc" '%u:%g' "${account_uid}:${account_gid}"
    runuser -u "${account_name}" -- test -w "${account_home}"
    runuser -u "${account_name}" -- test -w "${account_home}/.docker"
    runuser -u "${account_name}" -- test -w /workspace
}

# Force a late write-check failure and verify the completion marker is absent.
runuser() {
    if [[ "${!#}" == "${account_home}/.docker" ]]; then
        return 1
    fi
    command runuser "$@"
}
if (run_setup) 2>/tmp/expected-home-initialization-failure.log; then
    printf 'FAIL: injected %s home initialization failure was ignored\n' \
        "${host_platform}" >&2
    exit 1
fi
unset -f runuser
grep -Fq 'is not writable by permission-test' \
    /tmp/expected-home-initialization-failure.log
[[ ! -e "${account_home}/.docker-vm-home-initialized" ]]

# A retry must complete the partial initialization and create the marker last.
run_setup
assert_common_state
runuser -u "${account_name}" -- sh -c \
    'printf preserved > "$1/restart-sentinel"' _ "${account_home}"

# A marker-bearing home from the buggy release must be repaired on restart.
chown root:root "${account_home}" "${account_home}/.docker" /workspace
chmod 0755 "${account_home}" "${account_home}/.docker" /workspace
run_setup
assert_common_state
[[ "$(<"${account_home}/restart-sentinel")" == preserved ]]

if [[ "${host_platform}" == linux ]]; then
    assert_stat "${account_home}" '%u:%g' "${account_uid}:${account_gid}"
    assert_stat "${account_home}" '%a' '750'
    assert_stat /workspace '%u:%g' "${account_uid}:${account_gid}"
    assert_stat /workspace '%a' '770'
else
    assert_stat "${account_home}" '%u:%g' '0:0'
    assert_stat "${account_home}" '%a' '777'
    assert_stat /workspace '%u:%g' '0:0'
    assert_stat /workspace '%a' '777'
fi

runuser -u "${account_name}" -- sh -c \
    'umask 077; : > "$1/.Xauthority"; : > "$1/.xorgxrdp.10.log"' \
    _ "${account_home}"
assert_stat "${account_home}/.Xauthority" '%u:%g' "${account_uid}:${account_gid}"
assert_stat "${account_home}/.xorgxrdp.10.log" '%u:%g' "${account_uid}:${account_gid}"
printf '%s persistent home permission test passed.\n' "${host_platform}"
CONTAINER_TEST
done

printf 'Desktop home permission runtime tests passed.\n'
