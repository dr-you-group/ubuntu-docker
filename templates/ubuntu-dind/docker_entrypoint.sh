#!/usr/bin/env bash
set -Eeuo pipefail

readonly account_name="${ACCOUNT_NAME:?ACCOUNT_NAME is required}"
readonly password_file="${ACCOUNT_PASSWORD_FILE:-/run/secrets/login_password}"
readonly authorized_keys_file="${ACCOUNT_AUTHORIZED_KEYS_FILE:-/run/secrets/ssh_authorized_keys}"
readonly account_home="/home/${account_name}"
readonly host_platform="${HOST_PLATFORM:-windows}"
readonly gpu_enabled="${GPU_ENABLED:-0}"

if ! id "${account_name}" >/dev/null 2>&1; then
    printf 'ERROR: configured account does not exist: %s\n' "${account_name}" >&2
    exit 1
fi

if [[ ! -r "${password_file}" ]]; then
    printf 'ERROR: password secret is not readable: %s\n' "${password_file}" >&2
    exit 1
fi

if [[ ! -r "${authorized_keys_file}" || ! -s "${authorized_keys_file}" ]]; then
    printf 'ERROR: SSH authorized-keys secret is not readable: %s\n' "${authorized_keys_file}" >&2
    exit 1
fi

mapfile -t authorized_key_lines < <(awk 'NF { print }' "${authorized_keys_file}")
if (( ${#authorized_key_lines[@]} != 1 )); then
    printf 'ERROR: SSH authorized-keys secret must contain exactly one public key\n' >&2
    exit 1
fi
read -r authorized_key_type authorized_key_blob _ <<<"${authorized_key_lines[0]}"
if [[ "${authorized_key_type}" != ssh-rsa ||
      ! "${authorized_key_blob}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
    printf 'ERROR: SSH authorized-keys secret must contain one RSA public key without options\n' >&2
    exit 1
fi
canonical_authorized_key="${authorized_key_type} ${authorized_key_blob}"
if ! printf '%s\n' "${canonical_authorized_key}" | ssh-keygen -l -f - >/dev/null 2>&1; then
    printf 'ERROR: SSH authorized-keys secret contains an invalid RSA public key\n' >&2
    exit 1
fi

account_password="$(<"${password_file}")"
if [[ -z "${account_password}" ]]; then
    printf 'ERROR: password secret is empty\n' >&2
    exit 1
fi

printf '%s:%s\n' "${account_name}" "${account_password}" | chpasswd
unset account_password

readonly account_uid="$(id -u "${account_name}")"
readonly account_gid="$(id -g "${account_name}")"

# Keep authorized keys outside the bind-mounted home. Docker Desktop bind
# permissions can otherwise make OpenSSH StrictModes reject a valid key.
readonly installed_authorized_key="/etc/ssh/authorized_keys/${account_name}"
install -d -m 0755 -o root -g root /etc/ssh/authorized_keys
install -m 0644 -o root -g root /dev/null "${installed_authorized_key}"
printf '%s\n' "${canonical_authorized_key}" >"${installed_authorized_key}"

if [[ "${gpu_enabled}" == 1 ]]; then
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        printf 'ERROR: GPU mode is enabled but nvidia-smi was not injected by the host runtime\n' >&2
        exit 1
    fi
    nvidia-smi -L
fi

# BEGIN persistent-bind-storage
if [[ "${host_platform}" == linux ]]; then
    install -d -m 0750 -o "${account_uid}" -g "${account_gid}" "${account_home}"
    install -d -m 0770 -o "${account_uid}" -g "${account_gid}" /workspace
else
    # Keep Windows bind roots owned by the Docker Desktop side. Changing root
    # ownership can prevent PowerShell from renaming the host directory.
    install -d -m 0777 "${account_home}"
    install -d -m 0777 /workspace
    # The bind directories already exist when the container starts. GNU
    # install does not update the mode of an existing directory, so apply the
    # Docker Desktop/DrvFS-compatible mode explicitly on every startup.
    chmod 0777 "${account_home}" /workspace
fi

for writable_path in "${account_home}" /workspace; do
    if ! runuser -u "${account_name}" -- test -w "${writable_path}"; then
        echo "ERROR: ${writable_path} is not writable by ${account_name}; check the bind-mount ACL and mode." >&2
        exit 1
    fi
done

# A bind-mounted empty home hides files created by useradd in the image.
home_needs_initialization=false
if [[ ! -e "${account_home}/.docker-vm-home-initialized" ]]; then
    home_needs_initialization=true
    cp -a --update=none /etc/skel/. "${account_home}/"
    find "${account_home}" -mindepth 1 -exec chown -h "${account_uid}:${account_gid}" {} +
fi

# cp -a preserves the root-owned /etc/skel directory metadata on the home bind
# root. Restore platform-appropriate bind permissions after initialization so
# XRDP can create .Xauthority and its per-session Xorg log in the user's home.
if [[ "${host_platform}" == linux ]]; then
    chown "${account_uid}:${account_gid}" "${account_home}" /workspace
    chmod 0750 "${account_home}"
    chmod 0770 /workspace
else
    chmod 0777 "${account_home}" /workspace
fi

if [[ ! -e "${account_home}/workspace" ]]; then
    ln -s /workspace "${account_home}/workspace"
    chown -h "${account_uid}:${account_gid}" "${account_home}/workspace"
fi

install -d -m 0700 -o "${account_uid}" -g "${account_gid}" \
    "${account_home}/.docker" \
    "${account_home}/.docker/dind-certs"

for writable_path in "${account_home}" "${account_home}/.docker" /workspace; do
    if ! runuser -u "${account_name}" -- test -w "${writable_path}"; then
        echo "ERROR: ${writable_path} is not writable by ${account_name}; check the bind-mount ACL and mode." >&2
        exit 1
    fi
done

# Write the marker last so an interrupted copy or permission repair is retried.
if [[ "${home_needs_initialization}" == true ]]; then
    runuser -u "${account_name}" -- touch "${account_home}/.docker-vm-home-initialized"
fi
# END persistent-bind-storage

certificates_ready=false
for attempt in $(seq 1 120); do
    if [[ -s /certs/client/ca.pem && -s /certs/client/cert.pem && -s /certs/client/key.pem ]]; then
        certificates_ready=true
        break
    fi
    sleep 1
done

if [[ "${certificates_ready}" != true ]]; then
    printf 'ERROR: DinD client TLS certificates were not generated in time\n' >&2
    exit 1
fi

install -m 0600 -o "${account_uid}" -g "${account_gid}" \
    /certs/client/ca.pem "${account_home}/.docker/dind-certs/ca.pem"
install -m 0600 -o "${account_uid}" -g "${account_gid}" \
    /certs/client/cert.pem "${account_home}/.docker/dind-certs/cert.pem"
install -m 0600 -o "${account_uid}" -g "${account_gid}" \
    /certs/client/key.pem "${account_home}/.docker/dind-certs/key.pem"

cat > /etc/profile.d/docker_dind.sh <<EOF
export DOCKER_HOST=tcp://docker:2376
export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH=${account_home}/.docker/dind-certs
EOF
chmod 0644 /etc/profile.d/docker_dind.sh

# PAM reads /etc/environment for both interactive and non-interactive SSH
# sessions. Keep these values there as well as in profile.d.
sed -i '/^DOCKER_HOST=/d;/^DOCKER_TLS_VERIFY=/d;/^DOCKER_CERT_PATH=/d' /etc/environment
cat >> /etc/environment <<EOF
DOCKER_HOST=tcp://docker:2376
DOCKER_TLS_VERIFY=1
DOCKER_CERT_PATH=${account_home}/.docker/dind-certs
EOF

cat > /etc/sudoers.d/docker-dind-env <<'EOF'
Defaults env_keep += "DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH"
EOF
chmod 0440 /etc/sudoers.d/docker-dind-env
visudo -cf /etc/sudoers.d/docker-dind-env >/dev/null

export DOCKER_HOST=tcp://docker:2376
export DOCKER_TLS_VERIFY=1
export DOCKER_CERT_PATH="${account_home}/.docker/dind-certs"

docker_ready=false
for attempt in $(seq 1 60); do
    if runuser -u "${account_name}" -- env \
        DOCKER_HOST="${DOCKER_HOST}" \
        DOCKER_TLS_VERIFY="${DOCKER_TLS_VERIFY}" \
        DOCKER_CERT_PATH="${DOCKER_CERT_PATH}" \
        docker info >/dev/null 2>&1; then
        docker_ready=true
        break
    fi
    sleep 1
done

if [[ "${docker_ready}" != true ]]; then
    printf 'ERROR: cannot connect to the DinD engine over TLS\n' >&2
    exit 1
fi

install -d -m 0755 /run/sshd /run/dbus /var/log/supervisor
install -d -m 0700 -o "${account_uid}" -g "${account_gid}" "/run/user/${account_uid}"
install -d -m 1777 -o root -g root /tmp/.X11-unix
install -d -m 1777 -o root -g root /tmp/.ICE-unix

printf 'AllowUsers %s\n' "${account_name}" \
    > /etc/ssh/sshd_config.d/99-docker-vm-user.conf

dbus-uuidgen --ensure=/etc/machine-id
readonly host_key_directory=/etc/ssh/host_keys
install -d -m 0700 -o root -g root "${host_key_directory}"
for key_type in rsa ecdsa ed25519; do
    private_key="${host_key_directory}/ssh_host_${key_type}_key"
    if [[ ! -s "${private_key}" || ! -s "${private_key}.pub" ]]; then
        rm -f "${private_key}" "${private_key}.pub"
        ssh-keygen -q -t "${key_type}" -N '' -f "${private_key}"
    fi
    chmod 0600 "${private_key}"
    chmod 0644 "${private_key}.pub"
    ln -sfn "host_keys/$(basename "${private_key}")" "/etc/ssh/$(basename "${private_key}")"
    ln -sfn "host_keys/$(basename "${private_key}.pub")" "/etc/ssh/$(basename "${private_key}.pub")"
done
sshd -t
effective_sshd_config="$(sshd -T -C "user=${account_name},host=${account_name},addr=127.0.0.1")"
grep -qx 'strictmodes yes' <<<"${effective_sshd_config}"
grep -qx 'pubkeyauthentication yes' <<<"${effective_sshd_config}"
grep -qx 'passwordauthentication no' <<<"${effective_sshd_config}"
grep -qx 'kbdinteractiveauthentication no' <<<"${effective_sshd_config}"
grep -qx 'authenticationmethods publickey' <<<"${effective_sshd_config}"
grep -qx 'authorizedkeysfile /etc/ssh/authorized_keys/%u' <<<"${effective_sshd_config}"
grep -qx 'permitrootlogin no' <<<"${effective_sshd_config}"
grep -qx "allowusers ${account_name}" <<<"${effective_sshd_config}"

rm -f /run/xrdp/xrdp.pid /run/xrdp/xrdp-sesman.pid
rm -rf /run/xrdp/sockdir
/bin/sh /usr/share/xrdp/socksetup

exec "$@"
