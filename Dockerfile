FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Seoul
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

RUN apt-get update && apt-get install -y \
    sudo curl wget ca-certificates gnupg openssl \
    xfce4 xfce4-goodies xfce4-terminal xterm exo-utils \
    xrdp xorgxrdp dbus-x11 dbus x11-xserver-utils xauth \
    openssh-server \
    fcitx5 fcitx5-hangul fcitx5-config-qt im-config \
    git vim nano htop tmux less locales tzdata \
    python3 python3-pip python3-venv build-essential \
    iproute2 net-tools iputils-ping procps psmisc lsof rsync \
    fonts-noto-cjk fonts-noto-color-emoji language-pack-ko \
    && locale-gen en_US.UTF-8 ko_KR.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Tailscale install
RUN mkdir -p --mode=0755 /usr/share/keyrings && \
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg && \
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list \
      -o /etc/apt/sources.list.d/tailscale.list && \
    apt-get update && \
    apt-get install -y tailscale && \
    rm -rf /var/lib/apt/lists/*

# Global Fcitx5 environment for Korean input
RUN printf '%s\n' \
  'export GTK_IM_MODULE=fcitx' \
  'export QT_IM_MODULE=fcitx' \
  'export XMODIFIERS=@im=fcitx' \
  'export INPUT_METHOD=fcitx' \
  'export SDL_IM_MODULE=fcitx' \
  > /etc/profile.d/90-fcitx5.sh && \
  chmod +x /etc/profile.d/90-fcitx5.sh

# XRDP settings
RUN adduser xrdp ssl-cert || true && \
    sed -i 's/^MaxSessions=.*/MaxSessions=50/' /etc/xrdp/sesman.ini || true && \
    sed -i 's/^KillDisconnected=.*/KillDisconnected=false/' /etc/xrdp/sesman.ini || true && \
    sed -i 's/^IdleTimeLimit=.*/IdleTimeLimit=0/' /etc/xrdp/sesman.ini || true && \
    sed -i 's/^Policy=.*/Policy=UBC/' /etc/xrdp/sesman.ini || true && \
    printf '%s\n' \
      '#!/bin/sh' \
      'export GTK_IM_MODULE=fcitx' \
      'export QT_IM_MODULE=fcitx' \
      'export XMODIFIERS=@im=fcitx' \
      'export INPUT_METHOD=fcitx' \
      'export SDL_IM_MODULE=fcitx' \
      'export XDG_RUNTIME_DIR="/tmp/runtime-${USER}"' \
      'mkdir -p "$XDG_RUNTIME_DIR"' \
      'chmod 700 "$XDG_RUNTIME_DIR"' \
      'exec dbus-run-session -- sh -c "fcitx5 -d; exec startxfce4"' \
      > /etc/xrdp/startwm.sh && \
    chmod +x /etc/xrdp/startwm.sh

# SSH settings
RUN mkdir -p /etc/ssh/sshd_config.d && \
    printf '%s\n' \
      'Port 22' \
      'PasswordAuthentication yes' \
      'PubkeyAuthentication yes' \
      'PermitRootLogin no' \
      'UsePAM yes' \
      'X11Forwarding yes' \
      'AllowGroups labusers' \
      'HostKey /config/ssh/ssh_host_ed25519_key' \
      'HostKey /config/ssh/ssh_host_rsa_key' \
      > /etc/ssh/sshd_config.d/99-dcp-ubuntu.conf && \
    sed -i 's/^session[[:space:]]\+required[[:space:]]\+pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd || true

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 3389

CMD ["/entrypoint.sh"]
