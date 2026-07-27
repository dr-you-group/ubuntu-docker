FROM ubuntu:26.04

ARG ENVIRONMENT_NAME
ARG ACCOUNT_NAME
ARG ACCOUNT_UID=1001
ARG ACCOUNT_GID=1001
ARG DOCKER_VERSION=29.6.2

LABEL org.opencontainers.image.title="Ubuntu DinD desktop environment"
LABEL org.opencontainers.image.description="Ubuntu 26.04 with Xfce, XRDP, OpenSSH, Docker CLI, and an isolated DinD engine"

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    TZ=Asia/Seoul \
    PATH=/usr/lib/wsl/lib:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Ubuntu 26.04 reserves UID/GID 1000 for an unused default account. Remove it so
# Linux hosts can map their current user into the desktop container without a
# groupadd/useradd collision. The generated account is created below.
RUN if getent passwd ubuntu >/dev/null 2>&1; then userdel --remove ubuntu; fi \
    && if getent group ubuntu >/dev/null 2>&1; then groupdel ubuntu; fi

# im-config must not select systemd-cat when the container has no journal socket.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/packages.mozilla.org.asc \
    && test "$(gpg --show-keys --with-colons /etc/apt/keyrings/packages.mozilla.org.asc \
        | awk -F: '$1 == "fpr" { print $10; exit }')" = "35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3" \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc \
    && test "$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc \
        | awk -F: '$1 == "fpr" { print $10; exit }')" = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88" \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: https://packages.mozilla.org/apt' \
        'Suites: mozilla' \
        'Components: main' \
        'Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc' \
        > /etc/apt/sources.list.d/mozilla.sources \
    && printf '%s\n' \
        'Package: *' \
        'Pin: origin packages.mozilla.org' \
        'Pin-Priority: 1000' \
        > /etc/apt/preferences.d/mozilla \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: https://download.docker.com/linux/ubuntu' \
        'Suites: resolute' \
        'Components: stable' \
        "Architectures: $(dpkg --print-architecture)" \
        'Signed-By: /etc/apt/keyrings/docker.asc' \
        > /etc/apt/sources.list.d/docker.sources \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        dbus \
        dbus-x11 \
        dconf-cli \
        "docker-ce-cli=5:${DOCKER_VERSION}-1~ubuntu.26.04~resolute" \
        docker-buildx-plugin \
        docker-compose-plugin \
        firefox \
        fonts-noto-cjk \
        git \
        ibus \
        ibus-gtk3 \
        ibus-gtk4 \
        ibus-hangul \
        im-config \
        libglib2.0-bin \
        locales \
        openssh-server \
        procps \
        sudo \
        supervisor \
        tzdata \
        xfce4 \
        xfce4-terminal \
        xauth \
        xorgxrdp \
        xrdp \
    && sed -i \
        's|if \[ -e /usr/bin/systemd-cat \] ; then|if [ -e /usr/bin/systemd-cat ] \&\& [ -S /run/systemd/journal/socket ] ; then|' \
        /usr/share/im-config/initializer \
    && grep -Fqx \
        'if [ -e /usr/bin/systemd-cat ] && [ -S /run/systemd/journal/socket ] ; then' \
        /usr/share/im-config/initializer \
    && locale-gen en_US.UTF-8 ko_KR.UTF-8 \
    && ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && printf '%s\n' "${TZ}" > /etc/timezone \
    && groupadd --gid "${ACCOUNT_GID}" "${ACCOUNT_NAME}" \
    && useradd --create-home --shell /bin/bash --uid "${ACCOUNT_UID}" \
        --gid "${ACCOUNT_GID}" --groups sudo "${ACCOUNT_NAME}" \
    && usermod --append --groups ssl-cert xrdp \
    && sed -i 's/^#SessionSockdirGroup=root$/SessionSockdirGroup=xrdp/' /etc/xrdp/sesman.ini \
    && grep -qx 'SessionSockdirGroup=xrdp' /etc/xrdp/sesman.ini \
    && test -x /usr/bin/firefox \
    && test -x /usr/bin/docker \
    && docker compose version \
    && docker buildx version \
    && ln -sf /usr/bin/firefox /usr/local/bin/www-browser \
    && mkdir -p /run/sshd /var/log/supervisor /workspace \
    && rm -f /etc/ssh/ssh_host_* \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /usr/share/xfce4/backdrops \
    && ln -s /usr/share/backgrounds/xfce/xfce-blue.jpg /usr/share/xfce4/backdrops/xubuntu-wallpaper.png

COPY ssh-container.conf /etc/ssh/sshd_config.d/00-docker-vm-container.conf
COPY xrdp_startwm.sh /etc/xrdp/startwm.sh
COPY start_xfce_session.sh /usr/local/sbin/start_xfce_session.sh
COPY supervisord.conf /etc/supervisor/conf.d/docker-vm.conf
COPY docker_entrypoint.sh /usr/local/sbin/docker_vm_entrypoint.sh

RUN chmod 0755 /etc/xrdp/startwm.sh \
        /usr/local/sbin/start_xfce_session.sh \
        /usr/local/sbin/docker_vm_entrypoint.sh

# 3389 is only the container-internal XRDP port. The generator forbids host port 3389.
EXPOSE 22 3389

HEALTHCHECK --interval=15s --timeout=8s --start-period=90s --retries=8 \
    CMD pgrep -x dbus-daemon >/dev/null \
        && pgrep -x sshd >/dev/null \
        && pgrep -x xrdp >/dev/null \
        && pgrep -x xrdp-sesman >/dev/null \
        && docker info >/dev/null 2>&1 \
        || exit 1

ENTRYPOINT ["/usr/local/sbin/docker_vm_entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/docker-vm.conf"]
