#!/bin/sh

gsettings set org.freedesktop.ibus.general preload-engines "['hangul']"
gsettings set org.freedesktop.ibus.general engines-order "['hangul']"
gsettings set org.freedesktop.ibus.general use-global-engine true
gsettings set org.freedesktop.ibus.general.hotkey trigger "[]"
gsettings set org.freedesktop.ibus.general.hotkey triggers "[]"
gsettings set org.freedesktop.ibus.engine.hangul initial-input-mode "'latin'"
gsettings set org.freedesktop.ibus.engine.hangul disable-latin-mode false
gsettings set org.freedesktop.ibus.engine.hangul hangul-keyboard "'2'"
gsettings set org.freedesktop.ibus.engine.hangul switch-keys \
    "'Hangul,Shift+space,Control+space'"

ibus-daemon --daemonize --replace --xim

for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ibus engine hangul >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

exec startxfce4
