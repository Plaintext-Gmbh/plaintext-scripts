#!/usr/bin/env bash
# Baut das gemeinsame Plaintext-Runtime-Image (M3: Jar im Volume) und lädt es auf den NAS.
# Stabiles, app-agnostisches Image — selten neu zu bauen (nur bei JRE-/Base-Wechsel).
#
#   ./build-runtime.sh            # bauen + auf NAS laden
#   ./build-runtime.sh build      # nur lokal bauen
set -euo pipefail

IMAGE="plaintext-runtime:jre25"
NAS_HOST="${NAS_HOST:-192.100.0.1}"     # via Twingate von der Linux-Box; 192.168.1.224 im LAN
DEPLOY_SERVER="mad@${NAS_HOST}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Build ${IMAGE} (linux/amd64) ==="
docker build --platform linux/amd64 -t "${IMAGE}" "${DIR}"

if [ "${1:-}" = "build" ]; then
    echo "Nur-Build fertig: ${IMAGE}"
    exit 0
fi

echo "=== Save + Transfer + Load auf ${DEPLOY_SERVER} ==="
TMP="/tmp/plaintext-runtime-jre25.tar.gz"
docker save "${IMAGE}" | gzip > "${TMP}"
echo "Image-Tarball: $(du -h "${TMP}" | cut -f1)"
cat "${TMP}" | ssh "${DEPLOY_SERVER}" "cat > /tmp/plaintext-runtime-jre25.tar.gz && \
    sudo docker load -i /tmp/plaintext-runtime-jre25.tar.gz && \
    rm -f /tmp/plaintext-runtime-jre25.tar.gz"
rm -f "${TMP}"
echo "=== ${IMAGE} ist auf dem NAS geladen ✓ ==="
ssh "${DEPLOY_SERVER}" "sudo docker images ${IMAGE} --format '{{.Repository}}:{{.Tag}} ({{.Size}})'"
