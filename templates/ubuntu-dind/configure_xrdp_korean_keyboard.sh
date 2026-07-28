#!/bin/sh
set -eu

xrdp_config_dir="${XRDP_CONFIG_DIR:-/etc/xrdp}"
keyboard_config="${xrdp_config_dir}/xrdp_keyboard.ini"
base_keymap="${xrdp_config_dir}/km-00000412.ini"
hangul_keymap="${xrdp_config_dir}/km-e0010412.ini"

for required_file in "${keyboard_config}" "${base_keymap}"; do
    if [ ! -f "${required_file}" ]; then
        printf 'Required XRDP keyboard file is missing: %s\n' "${required_file}" >&2
        exit 1
    fi
done

temporary_keymap="$(mktemp "${xrdp_config_dir}/.km-e0010412.ini.XXXXXX")"
cleanup() {
    rm -f -- "${temporary_keymap}"
}
trap cleanup EXIT HUP INT TERM

sed \
    -e 's/\r$//' \
    -e 's/^Key109=.*/Key109=65332:0/' \
    -e 's/^Key113=.*/Key113=65329:0/' \
    "${base_keymap}" >"${temporary_keymap}"
chmod 0644 "${temporary_keymap}"

hangul_count="$(grep -Fxc -- 'Key113=65329:0' "${temporary_keymap}" || true)"
hanja_count="$(grep -Fxc -- 'Key109=65332:0' "${temporary_keymap}" || true)"
if [ "${hangul_count}" -ne 8 ] || [ "${hanja_count}" -ne 8 ]; then
    printf 'Unexpected Korean XRDP key count: Hangul=%s Hanja=%s\n' \
        "${hangul_count}" "${hanja_count}" >&2
    exit 1
fi
if ! awk '
    BEGIN {
        expected["noshift"] = expected["shift"] = 1
        expected["altgr"] = expected["shiftaltgr"] = 1
        expected["capslock"] = expected["capslockaltgr"] = 1
        expected["shiftcapslock"] = expected["shiftcapslockaltgr"] = 1
    }
    /^\[[^]]+\]$/ {
        section = substr($0, 2, length($0) - 2)
        next
    }
    $0 == "Key113=65329:0" { hangul[section]++ }
    $0 == "Key109=65332:0" { hanja[section]++ }
    END {
        failed = 0
        for (section in expected) {
            if (hangul[section] != 1 || hanja[section] != 1) {
                printf "Unexpected Korean keys in [%s]: Hangul=%d Hanja=%d\n", \
                    section, hangul[section], hanja[section] > "/dev/stderr"
                failed = 1
            }
        }
        exit failed
    }
' "${temporary_keymap}"; then
    exit 1
fi

mv -f -- "${temporary_keymap}" "${hangul_keymap}"
temporary_keymap=''
trap - EXIT HUP INT TERM

if ! grep -Fqx -- '[rdp_keyboard_kr_hangul]' "${keyboard_config}"; then
    cat >>"${keyboard_config}" <<'EOF'

; Korean 106-key keyboard backport for XRDP 0.10.x (upstream #3598)
[rdp_layouts_kr_hangul]
rdp_layout_kr_hangul=0xe0010412

[layouts_map_kr_hangul]
rdp_layout_kr_hangul=kr

[rdp_keyboard_kr_hangul]
keyboard_type=8
keyboard_subtype=1
model=pc105
variant=kr106
options=korean:ralt_hangul,korean:rctrl_hanja
rdp_layouts=rdp_layouts_kr_hangul
layouts_map=layouts_map_kr_hangul
EOF
fi

if ! awk '
    $0 == "[rdp_layouts_kr_hangul]" {
        section = "rdp_layouts"
        rdp_layouts_headers++
        next
    }
    $0 == "[layouts_map_kr_hangul]" {
        section = "layouts_map"
        layouts_map_headers++
        next
    }
    $0 == "[rdp_keyboard_kr_hangul]" {
        section = "keyboard"
        keyboard_headers++
        next
    }
    /^\[/ { section = "" }
    section == "rdp_layouts" && $0 == "rdp_layout_kr_hangul=0xe0010412" { layout_id++ }
    section == "layouts_map" && $0 == "rdp_layout_kr_hangul=kr" { layout_map++ }
    section == "keyboard" && $0 == "keyboard_type=8" { keyboard_type++ }
    section == "keyboard" && $0 == "keyboard_subtype=1" { keyboard_subtype++ }
    section == "keyboard" && $0 == "model=pc105" { model++ }
    section == "keyboard" && $0 == "variant=kr106" { variant++ }
    section == "keyboard" && $0 == "options=korean:ralt_hangul,korean:rctrl_hanja" { options++ }
    section == "keyboard" && $0 == "rdp_layouts=rdp_layouts_kr_hangul" { rdp_layouts_ref++ }
    section == "keyboard" && $0 == "layouts_map=layouts_map_kr_hangul" { layouts_map_ref++ }
    END {
        invalid = rdp_layouts_headers != 1 || layouts_map_headers != 1 || \
            keyboard_headers != 1 || layout_id != 1 || layout_map != 1 || \
            keyboard_type != 1 || keyboard_subtype != 1 || model != 1 || \
            variant != 1 || options != 1 || rdp_layouts_ref != 1 || \
            layouts_map_ref != 1
        if (invalid) {
            print "Invalid XRDP Korean keyboard section structure" > "/dev/stderr"
        }
        exit invalid
    }
' "${keyboard_config}"; then
    exit 1
fi
