#!/usr/bin/env bash
set -Eeuo pipefail

readonly repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly setup_script="${repo_root}/templates/ubuntu-dind/configure_xrdp_korean_keyboard.sh"
test_root="$(mktemp -d /tmp/ubuntu-docker-xrdp-keyboard.XXXXXXXX)"
readonly test_root
readonly xrdp_config_dir="${test_root}/xrdp"

cleanup() {
    case "${test_root}" in
        /tmp/ubuntu-docker-xrdp-keyboard.*) rm -rf -- "${test_root}" ;;
        *) printf 'Refusing to remove unexpected test path: %s\n' "${test_root}" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

value_count_in_section() {
    local ini_path="$1"
    local section_name="$2"
    local expected_value="$3"

    awk -v heading="[${section_name}]" -v value="${expected_value}" '
        $0 == heading {
            active = 1
            next
        }
        active && /^\[/ { active = 0 }
        active && $0 == value { count++ }
        END { print count + 0 }
    ' "${ini_path}"
}

assert_unique_value_in_section() {
    local ini_path="$1"
    local section_name="$2"
    local expected_value="$3"

    [[ "$(value_count_in_section "${ini_path}" "${section_name}" "${expected_value}")" == 1 ]] ||
        fail "Missing or duplicate value in [${section_name}]: ${expected_value}"
}

mkdir -p -- "${xrdp_config_dir}"
printf '%s\n' \
    '[default]' \
    'rdp_layouts=default_rdp_layouts' \
    'layouts_map=default_layouts_map' \
    >"${xrdp_config_dir}/xrdp_keyboard.ini"

section_index=0
for section_name in \
    noshift shift altgr shiftaltgr \
    capslock capslockaltgr shiftcapslock shiftcapslockaltgr; do
    if (( section_index % 2 == 0 )); then
        right_alt_keysym=65514
    else
        right_alt_keysym=65512
    fi
    printf '[%s]\r\nKey42=103:103\r\nKey109=65508:0\r\nKey113=%s:0\r\n' \
        "${section_name}" "${right_alt_keysym}"
    section_index=$((section_index + 1))
done >"${xrdp_config_dir}/km-00000412.ini"

XRDP_CONFIG_DIR="${xrdp_config_dir}" sh "${setup_script}"

readonly hangul_keymap="${xrdp_config_dir}/km-e0010412.ini"
readonly keyboard_config="${xrdp_config_dir}/xrdp_keyboard.ini"
[[ -f "${hangul_keymap}" ]] || fail 'Extended Korean XRDP keymap was not created'
[[ "$(grep -Fxc -- 'Key113=65329:0' "${hangul_keymap}")" == 8 ]] ||
    fail 'Hangul keysym is not present in all eight modifier sections'
[[ "$(grep -Fxc -- 'Key109=65332:0' "${hangul_keymap}")" == 8 ]] ||
    fail 'Hangul_Hanja keysym is not present in all eight modifier sections'
[[ "$(grep -Fxc -- 'Key42=103:103' "${hangul_keymap}")" == 8 ]] ||
    fail 'Unrelated key mappings were not preserved'
! grep -q $'\r' "${hangul_keymap}" || fail 'Generated keymap contains CRLF'

for modifier_section in \
    noshift shift altgr shiftaltgr \
    capslock capslockaltgr shiftcapslock shiftcapslockaltgr; do
    [[ "$(value_count_in_section "${hangul_keymap}" "${modifier_section}" 'Key113=65329:0')" == 1 ]] ||
        fail "Hangul mapping is not unique in [${modifier_section}]"
    [[ "$(value_count_in_section "${hangul_keymap}" "${modifier_section}" 'Key109=65332:0')" == 1 ]] ||
        fail "Hangul_Hanja mapping is not unique in [${modifier_section}]"
done

for required_section in \
    '[rdp_layouts_kr_hangul]' \
    '[layouts_map_kr_hangul]' \
    '[rdp_keyboard_kr_hangul]'; do
    [[ "$(grep -Fxc -- "${required_section}" "${keyboard_config}")" == 1 ]] ||
        fail "Missing or duplicate XRDP section: ${required_section}"
done

assert_unique_value_in_section "${keyboard_config}" rdp_layouts_kr_hangul \
    'rdp_layout_kr_hangul=0xe0010412'
assert_unique_value_in_section "${keyboard_config}" layouts_map_kr_hangul \
    'rdp_layout_kr_hangul=kr'
for required_setting in \
    'keyboard_type=8' 'keyboard_subtype=1' 'model=pc105' 'variant=kr106' \
    'options=korean:ralt_hangul,korean:rctrl_hanja' \
    'rdp_layouts=rdp_layouts_kr_hangul' \
    'layouts_map=layouts_map_kr_hangul'; do
    assert_unique_value_in_section "${keyboard_config}" rdp_keyboard_kr_hangul \
        "${required_setting}"
done

readonly first_keymap_hash="$(sha256sum "${hangul_keymap}")"
readonly first_config_hash="$(sha256sum "${keyboard_config}")"
XRDP_CONFIG_DIR="${xrdp_config_dir}" sh "${setup_script}"
[[ "$(sha256sum "${hangul_keymap}")" == "${first_keymap_hash}" ]] ||
    fail 'Korean keymap setup is not idempotent'
[[ "$(sha256sum "${keyboard_config}")" == "${first_config_hash}" ]] ||
    fail 'XRDP keyboard configuration setup is not idempotent'

readonly malformed_config_dir="${test_root}/malformed-xrdp"
mkdir -p -- "${malformed_config_dir}"
printf '%s\n' \
    '[default]' \
    'rdp_layouts=default_rdp_layouts' \
    'layouts_map=default_layouts_map' \
    >"${malformed_config_dir}/xrdp_keyboard.ini"
{
    for section_name in \
        noshift shift altgr shiftaltgr \
        capslock capslockaltgr shiftcapslock shiftcapslockaltgr; do
        printf '[%s]\nKey109=65508:0\n' "${section_name}"
        case "${section_name}" in
            noshift)
                printf 'Key113=65514:0\nKey113=65512:0\n'
                ;;
            shiftcapslockaltgr)
                ;;
            *)
                printf 'Key113=65514:0\n'
                ;;
        esac
    done
} >"${malformed_config_dir}/km-00000412.ini"
if XRDP_CONFIG_DIR="${malformed_config_dir}" sh "${setup_script}" >/dev/null 2>&1; then
    fail 'Setup accepted duplicate and missing modifier-section mappings'
fi

printf 'XRDP Korean keyboard mapping test passed.\n'
