#!/bin/sh
set -eu

# Docker's namespace restrictions prevent Chromium's nested sandbox from
# starting. Keep the exception scoped to VS Code instead of relaxing the
# container-wide seccomp or AppArmor policy.
real_binary="${VSCODE_REAL_BINARY:-/usr/bin/code}"
exec "${real_binary}" --no-sandbox "$@"
