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

# ── Warum Datei + nassh und nicht `cat … | ssh … sudo docker load` (Karte 1215) ──────────────
#  Hier stand bis zum 14.09.2026:
#
#      cat "${TMP}" | ssh "${DEPLOY_SERVER}" "cat > /tmp/… && sudo docker load -i /tmp/… && rm -f …"
#
#  Das kann auf dieser Maschine nicht funktionieren. `docker` ist auf dem NAS nicht passwortfrei
#  — deshalb gibt es ~/scripts/nassh, das das sudo-Passwort aus dem Vault holt und **allein** auf
#  stdin schickt. In der Zeile oben ist stdin aber schon belegt, naemlich mit dem 74-MB-Tarball:
#  `sudo -S` bekommt seine Passwortzeile nie. Dasselbe Muster steht in Karte 774 (ein Kommando,
#  das stdin mitliest, verbraucht das Passwort bzw. laesst den Aufruf haengen).
#
#  Der Tarball geht deshalb per `scp` als Datei hinueber, und erst das Laden laeuft ueber `nassh`
#  — dessen stdin ist dann frei fuer das Passwort.
NASSH="${NASSH:-$HOME/scripts/nassh}"
[ -x "$NASSH" ] || { echo "FEHLER: $NASSH fehlt — ohne sudo-Weg auf den NAS geht das Laden nicht." >&2; exit 1; }

echo "=== Save + Transfer + Load auf ${DEPLOY_SERVER} ==="
TMP="/tmp/plaintext-runtime-jre25.tar.gz"
FERN="/tmp/plaintext-runtime-jre25.tar.gz"
docker save "${IMAGE}" | gzip > "${TMP}"
echo "Image-Tarball: $(du -h "${TMP}" | cut -f1)"

scp -q "${TMP}" "${DEPLOY_SERVER}:${FERN}"
"$NASSH" "docker load -i ${FERN}"
"$NASSH" "rm -f ${FERN}"
rm -f "${TMP}"

echo "=== Gegenprobe: dieselbe Image-Id hier und auf dem NAS? ==="
LOKAL="$(docker images "${IMAGE}" --format '{{.ID}}')"
FERN_ID="$("$NASSH" "docker images ${IMAGE} --format {{.ID}}" | tr -d '\r' | tail -1 | tr -d ' ')"
echo "  lokal: ${LOKAL}"
echo "  NAS  : ${FERN_ID}"
if [ -n "${LOKAL}" ] && [ "${LOKAL}" = "${FERN_ID}" ]; then
    echo "=== ${IMAGE} ist auf dem NAS geladen ✓ (Id stimmt ueberein) ==="
else
    echo "FEHLER: die Image-Id auf dem NAS stimmt nicht mit der lokal gebauten ueberein." >&2
    echo "        'geladen' waere hier eine Behauptung — bitte nachsehen, bevor deployt wird." >&2
    exit 1
fi
"$NASSH" "docker images ${IMAGE} --format {{.Repository}}:{{.Tag}}--{{.Size}}"

# Die Container ziehen das neue Image NICHT von selbst: sie laufen mit der alten Id weiter, bis
# sie neu erstellt werden. Das passiert beim naechsten Blue-Green-Rollout der jeweiligen App.
echo
echo "Hinweis: laufende Container behalten ihr altes Image, bis sie neu erstellt werden."
echo "         Wirkung pruefen mit:  nassh \"docker exec <container> java -version\""
