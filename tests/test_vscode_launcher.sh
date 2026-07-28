#!/usr/bin/env bash
set -Eeuo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly launcher="${repo_root}/templates/ubuntu-dind/vscode_launcher.sh"
readonly test_root="$(mktemp -d /tmp/ubuntu-docker-vscode.XXXXXXXX)"
readonly fake_code="${test_root}/fake-code"
readonly captured_arguments="${test_root}/arguments"

cleanup() {
    case "${test_root}" in
        /tmp/ubuntu-docker-vscode.*) rm -rf -- "${test_root}" ;;
        *) printf 'Refusing to remove unexpected test path: %s\n' "${test_root}" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

cat >"${fake_code}" <<'EOF'
#!/bin/sh
set -eu
: "${VSCODE_CAPTURE_FILE:?}"
printf '%s\0' "$@" >"${VSCODE_CAPTURE_FILE}"
exit "${VSCODE_FAKE_EXIT:-0}"
EOF
chmod 0755 "${fake_code}"

VSCODE_REAL_BINARY="${fake_code}" \
VSCODE_CAPTURE_FILE="${captured_arguments}" \
    "${launcher}" --new-window '/workspace/file with spaces.txt' --verbose

mapfile -d '' -t actual_arguments <"${captured_arguments}"
expected_arguments=(
    '--no-sandbox'
    '--new-window'
    '/workspace/file with spaces.txt'
    '--verbose'
)
[[ "${#actual_arguments[@]}" -eq "${#expected_arguments[@]}" ]] ||
    fail 'Launcher changed the VS Code argument count'
for index in "${!expected_arguments[@]}"; do
    [[ "${actual_arguments[index]}" == "${expected_arguments[index]}" ]] ||
        fail "Argument ${index} is '${actual_arguments[index]}', expected '${expected_arguments[index]}'"
done

set +e
VSCODE_REAL_BINARY="${fake_code}" \
VSCODE_CAPTURE_FILE="${captured_arguments}" \
VSCODE_FAKE_EXIT=37 \
    "${launcher}" --version
launcher_status=$?
set -e
[[ "${launcher_status}" -eq 37 ]] || fail "Launcher returned ${launcher_status}, expected 37"

printf 'VS Code container launcher tests passed.\n'
