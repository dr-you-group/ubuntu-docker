#!/bin/sh

unset DBUS_SESSION_BUS_ADDRESS
export LANG="${LANG:-en_US.UTF-8}"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus
export XMODIFIERS=@im=ibus

if [ -r /etc/profile ]; then
    . /etc/profile
fi

exec dbus-launch --exit-with-session /usr/local/sbin/start_xfce_session.sh
