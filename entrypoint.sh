#!/usr/bin/env bash
set -euo pipefail

USERS_LIST=(
  "labadmin:20000"
  "younwoo:20001"
  "hanjae:20002"
  "minsung:20003"
  "changhoon:20004"
  "jiwoo:20005"
)

PASS_FILE="/config/initial_passwords.txt"
TS_SOCKET="/var/run/tailscale/tailscaled.sock"

mkdir -p /config /config/ssh /workspace/shared /run/sshd /run/dbus /var/run/xrdp /var/lib/tailscale /var/run/tailscale
touch "$PASS_FILE"
chmod 600 "$PASS_FILE"

groupadd -f labusers

# Persistent SSH host keys
if [ ! -f /config/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -t ed25519 -f /config/ssh/ssh_host_ed25519_key -N ''
fi

if [ ! -f /config/ssh/ssh_host_rsa_key ]; then
  ssh-keygen -t rsa -b 4096 -f /config/ssh/ssh_host_rsa_key -N ''
fi

chmod 700 /config/ssh
chmod 600 /config/ssh/ssh_host_*_key
chmod 644 /config/ssh/ssh_host_*_key.pub

get_password() {
  local username="$1"
  local envvar
  local pw

  envvar="$(echo "${username}_PASSWORD" | tr '[:lower:]' '[:upper:]')"
  pw="${!envvar:-}"

  if grep -q "^${username}:" "$PASS_FILE"; then
    pw="$(grep "^${username}:" "$PASS_FILE" | head -n1 | cut -d: -f2-)"
  fi

  if [ -z "$pw" ]; then
    pw="$(openssl rand -hex 12)"
    echo "${username}:${pw}" >> "$PASS_FILE"
  elif ! grep -q "^${username}:" "$PASS_FILE"; then
    echo "${username}:${pw}" >> "$PASS_FILE"
  fi

  echo "$pw"
}

setup_fcitx5_for_user() {
  local username="$1"
  local home_dir="/home/${username}"

  mkdir -p "${home_dir}/.config/fcitx5/conf"
  mkdir -p "${home_dir}/.config/autostart"

  # Fcitx5 profile: English keyboard + Hangul input
  if [ ! -f "${home_dir}/.config/fcitx5/profile" ]; then
    cat > "${home_dir}/.config/fcitx5/profile" <<'PROFILE'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=hangul

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=hangul
Layout=

[GroupOrder]
0=Default
PROFILE
  fi

  # Input method environment for GUI sessions
  cat > "${home_dir}/.xinputrc" <<'XINPUTRC'
run_im fcitx5
XINPUTRC

  cat > "${home_dir}/.xsessionrc" <<'XSESSIONRC'
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
export INPUT_METHOD=fcitx
export SDL_IM_MODULE=fcitx
export XDG_RUNTIME_DIR="/tmp/runtime-${USER}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
XSESSIONRC

  cat > "${home_dir}/.config/autostart/fcitx5.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Exec=fcitx5 -d
X-GNOME-Autostart-enabled=true
DESKTOP

  chown -R "${username}:${username}" "${home_dir}/.config" "${home_dir}/.xinputrc" "${home_dir}/.xsessionrc"
}

for item in "${USERS_LIST[@]}"; do
  IFS=":" read -r username uid <<< "$item"
  password="$(get_password "$username")"

  if ! id "$username" >/dev/null 2>&1; then
    useradd -M -U -u "$uid" -d "/home/${username}" -s /bin/bash -G sudo,labusers "$username"
    echo "${username}:${password}" | chpasswd
  else
    usermod -aG sudo,labusers "$username" || true
  fi

  mkdir -p "/home/${username}" "/workspace/${username}"

  if [ ! -f "/home/${username}/.bashrc" ]; then
    cp -a /etc/skel/. "/home/${username}/" || true
  fi

  echo "startxfce4" > "/home/${username}/.xsession"

  ln -sfn "/workspace/${username}" "/home/${username}/workspace"
  ln -sfn "/workspace/shared" "/home/${username}/shared"

  setup_fcitx5_for_user "$username"

  chown -R "${username}:${username}" "/home/${username}" "/workspace/${username}"
  chown -h "${username}:${username}" "/home/${username}/workspace" "/home/${username}/shared" || true

  chmod 700 "/home/${username}" "/workspace/${username}"
done

chown root:labusers /workspace/shared
chmod 2770 /workspace/shared

# Passwordless sudo inside the container
echo "%labusers ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-labusers
chmod 0440 /etc/sudoers.d/90-labusers

# Start system dbus
dbus-daemon --system --fork || true

# Start SSH
/usr/sbin/sshd -D -e &

# Start XRDP
rm -f /var/run/xrdp/*.pid /var/run/xrdp-sesman.pid || true
/usr/sbin/xrdp-sesman
/usr/sbin/xrdp

# Start Tailscale in userspace mode
if [ -n "${TS_AUTHKEY:-}" ]; then
  echo "Starting tailscaled..."

  tailscaled \
    --tun=userspace-networking \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket="${TS_SOCKET}" \
    > /var/log/tailscaled.log 2>&1 &

  TAILSCALED_PID=$!
  sleep 5

  if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
    echo "WARNING: tailscaled exited early. Container will continue without Tailscale."
    echo "----- /var/log/tailscaled.log -----"
    cat /var/log/tailscaled.log || true
  else
    ts() {
      tailscale --socket="${TS_SOCKET}" "$@"
    }

    echo "Running tailscale up..."

    if ! ts up \
      --authkey="${TS_AUTHKEY}" \
      --hostname="${TS_HOSTNAME:-dcp-ubuntu}" \
      --accept-dns=false \
      ${TS_EXTRA_ARGS:-} \
      > /var/log/tailscale-up.log 2>&1; then

      echo "WARNING: tailscale up failed. Container will continue without Tailscale."
      echo "----- /var/log/tailscale-up.log -----"
      cat /var/log/tailscale-up.log || true

    else
      echo "Tailscale up succeeded."

      ts serve reset > /var/log/tailscale-serve.log 2>&1 || true

      if ! ts serve --yes --bg --tcp=3389 tcp://127.0.0.1:3389 >> /var/log/tailscale-serve.log 2>&1; then
        echo "WARNING: Tailscale Serve failed for RDP 3389."
      fi

      if ! ts serve --yes --bg --tcp=2222 tcp://127.0.0.1:22 >> /var/log/tailscale-serve.log 2>&1; then
        echo "WARNING: Tailscale Serve failed for SSH 2222."
      fi

      echo ""
      echo "Tailscale IP:"
      ts ip -4 || true

      echo ""
      echo "Tailscale Serve status:"
      ts serve status || true

      echo "----- /var/log/tailscale-serve.log -----"
      cat /var/log/tailscale-serve.log || true
    fi
  fi
else
  echo "TS_AUTHKEY is not set. Tailscale was not started."
fi

echo ""
echo "============================================================"
echo "Container name: dcp-ubuntu"
echo "Image name:     youlab/aisi-ubuntu-cuda"
echo ""
echo "Initial Linux/RDP/SSH passwords:"
echo "  docker exec -it dcp-ubuntu cat /config/initial_passwords.txt"
echo ""
echo "RDP:"
echo "  dcp-ubuntu:3389"
echo ""
echo "SSH:"
echo "  ssh -p 2222 <user>@dcp-ubuntu"
echo ""
echo "Korean input:"
echo "  Fcitx5 + Hangul is preconfigured."
echo "  In RDP session, use Fcitx5 Configuration if switching does not work."
echo "============================================================"
echo ""

touch /var/log/xrdp.log /var/log/xrdp-sesman.log
tail -F /var/log/xrdp.log /var/log/xrdp-sesman.log
