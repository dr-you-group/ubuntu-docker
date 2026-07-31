#!/usr/bin/env bash
set -Eeuo pipefail

readonly cert_root="${DOCKER_TLS_CERTDIR:-/certs}"
readonly ca_dir="${cert_root}/ca"
readonly server_dir="${cert_root}/server"
readonly client_dir="${cert_root}/client"
readonly gpu_enabled="${GPU_ENABLED:-0}"

umask 077
install -d -m 0700 "${ca_dir}" "${server_dir}" "${client_dir}"

if [[ ! -s "${ca_dir}/key.pem" || ! -s "${ca_dir}/cert.pem" ]]; then
    openssl genrsa -out "${ca_dir}/key.pem" 4096
    openssl req -new -x509 -days 3650 \
        -key "${ca_dir}/key.pem" \
        -sha256 -subj '/CN=ubuntu-dind-ca' \
        -out "${ca_dir}/cert.pem"
fi

if [[ ! -s "${server_dir}/key.pem" || ! -s "${server_dir}/cert.pem" ]]; then
    server_tmp="$(mktemp -d)"
    trap 'rm -rf "${server_tmp}"' EXIT
    openssl genrsa -out "${server_dir}/key.pem" 4096
    openssl req -new -key "${server_dir}/key.pem" \
        -subj '/CN=docker' -out "${server_tmp}/server.csr"
    cat > "${server_tmp}/server-ext.cnf" <<'EOF'
subjectAltName=DNS:docker,DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth
EOF
    openssl x509 -req -days 825 -sha256 \
        -in "${server_tmp}/server.csr" \
        -CA "${ca_dir}/cert.pem" -CAkey "${ca_dir}/key.pem" -CAcreateserial \
        -extfile "${server_tmp}/server-ext.cnf" \
        -out "${server_dir}/cert.pem"
    rm -rf "${server_tmp}"
    trap - EXIT
fi

if [[ ! -s "${client_dir}/key.pem" || ! -s "${client_dir}/cert.pem" ]]; then
    client_tmp="$(mktemp -d)"
    trap 'rm -rf "${client_tmp}"' EXIT
    openssl genrsa -out "${client_dir}/key.pem" 4096
    openssl req -new -key "${client_dir}/key.pem" \
        -subj '/CN=ubuntu-dind-client' -out "${client_tmp}/client.csr"
    printf 'extendedKeyUsage=clientAuth\n' > "${client_tmp}/client-ext.cnf"
    openssl x509 -req -days 825 -sha256 \
        -in "${client_tmp}/client.csr" \
        -CA "${ca_dir}/cert.pem" -CAkey "${ca_dir}/key.pem" -CAcreateserial \
        -extfile "${client_tmp}/client-ext.cnf" \
        -out "${client_dir}/cert.pem"
    rm -rf "${client_tmp}"
    trap - EXIT
fi

cp "${ca_dir}/cert.pem" "${client_dir}/ca.pem"
chmod 0400 "${ca_dir}/key.pem" "${server_dir}/key.pem" "${client_dir}/key.pem"
chmod 0444 "${ca_dir}/cert.pem" "${server_dir}/cert.pem" \
    "${client_dir}/cert.pem" "${client_dir}/ca.pem"

if [[ "${gpu_enabled}" == 1 ]]; then
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        printf 'ERROR: GPU mode is enabled but nvidia-smi was not injected into DinD\n' >&2
        exit 1
    fi
    if ! command -v nvidia-ctk >/dev/null 2>&1; then
        printf 'ERROR: GPU mode is enabled but NVIDIA Container Toolkit is missing\n' >&2
        exit 1
    fi

    nvidia-smi -L
    install -d -m 0755 /etc/docker /etc/cdi
    nvidia-ctk runtime configure --runtime=docker --config=/etc/docker/daemon.json
    if ! nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml; then
        printf 'WARNING: CDI generation failed; the NVIDIA Docker runtime will still be used\n' >&2
        rm -f /etc/cdi/nvidia.yaml
    fi
fi

# An abrupt host or Docker Desktop shutdown can leave this file in the
# container's writable layer. On restart it points at the new entrypoint
# process (PID 1), so dockerd incorrectly concludes that a daemon is running.
case "${1:-}" in
    dockerd|*/dockerd)
        rm -f /var/run/docker.pid
        ;;
esac

exec "$@"
