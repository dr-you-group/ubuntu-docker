#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="youlab/aisi-ubuntu-cuda"
CONTAINER_NAME="dcp-ubuntu"

if [ -z "${TS_AUTHKEY:-}" ]; then
  echo "ERROR: TS_AUTHKEY is required."
  echo ""
  echo "Example:"
  echo "  TS_AUTHKEY='tskey-auth-xxxxx' ./run.sh"
  exit 1
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Container already exists: $CONTAINER_NAME"
  echo ""
  echo "Use one of:"
  echo "  docker start $CONTAINER_NAME"
  echo "  docker restart $CONTAINER_NAME"
  echo "  docker logs -f $CONTAINER_NAME"
  echo ""
  echo "If you intentionally want to recreate it:"
  echo "  docker rm -f $CONTAINER_NAME"
  echo "  TS_AUTHKEY='tskey-auth-xxxxx' ./run.sh"
  exit 1
fi

docker volume create dcp_config >/dev/null
docker volume create dcp_tailscale_state >/dev/null

docker volume create dcp_home_labadmin >/dev/null
docker volume create dcp_home_younwoo >/dev/null
docker volume create dcp_home_hanjae >/dev/null
docker volume create dcp_home_minsung >/dev/null
docker volume create dcp_home_changhoon >/dev/null
docker volume create dcp_home_jiwoo >/dev/null

docker volume create dcp_ws_labadmin >/dev/null
docker volume create dcp_ws_younwoo >/dev/null
docker volume create dcp_ws_hanjae >/dev/null
docker volume create dcp_ws_minsung >/dev/null
docker volume create dcp_ws_changhoon >/dev/null
docker volume create dcp_ws_jiwoo >/dev/null
docker volume create dcp_ws_shared >/dev/null

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --gpus all \
  --shm-size=64g \
  -e TS_AUTHKEY="${TS_AUTHKEY}" \
  -e TS_HOSTNAME="${TS_HOSTNAME:-dcp-ubuntu}" \
  -e TS_EXTRA_ARGS="${TS_EXTRA_ARGS:-}" \
  -e LABADMIN_PASSWORD="${LABADMIN_PASSWORD:-}" \
  -e YOUNWOO_PASSWORD="${YOUNWOO_PASSWORD:-}" \
  -e HANJAE_PASSWORD="${HANJAE_PASSWORD:-}" \
  -e MINSUNG_PASSWORD="${MINSUNG_PASSWORD:-}" \
  -e CHANGHOON_PASSWORD="${CHANGHOON_PASSWORD:-}" \
  -e JIWOO_PASSWORD="${JIWOO_PASSWORD:-}" \
  -v dcp_config:/config \
  -v dcp_tailscale_state:/var/lib/tailscale \
  -v dcp_home_labadmin:/home/labadmin \
  -v dcp_home_younwoo:/home/younwoo \
  -v dcp_home_hanjae:/home/hanjae \
  -v dcp_home_minsung:/home/minsung \
  -v dcp_home_changhoon:/home/changhoon \
  -v dcp_home_jiwoo:/home/jiwoo \
  -v dcp_ws_labadmin:/workspace/labadmin \
  -v dcp_ws_younwoo:/workspace/younwoo \
  -v dcp_ws_hanjae:/workspace/hanjae \
  -v dcp_ws_minsung:/workspace/minsung \
  -v dcp_ws_changhoon:/workspace/changhoon \
  -v dcp_ws_jiwoo:/workspace/jiwoo \
  -v dcp_ws_shared:/workspace/shared \
  "$IMAGE_NAME"

echo "Started: $CONTAINER_NAME"
echo ""
echo "Logs:"
echo "  docker logs -f $CONTAINER_NAME"
echo ""
echo "Initial passwords:"
echo "  docker exec -it $CONTAINER_NAME cat /config/initial_passwords.txt"
