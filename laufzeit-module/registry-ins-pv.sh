#!/usr/bin/env bash
# Karte 1516 (Laufzeit-Module Schritt 5): registry.yaml (plaintext-modules, Format 2) ins PV einer
# Installation legen. Die Modul-Ansicht (root, Karte 1515) liest sie dort und schreibt daraus
# module.yaml fuer den ModulLader.
#
#   ./registry-ins-pv.sh <app> <env> [--ja]
#       app: Verzeichnis unter /volume1/docker (z.B. plaintext-root)
#       env: int | prod  (beide Blue-Green-Slots einer Umgebung teilen sich /data)
#   Ohne --ja wird nur geprueft und angezeigt, was geschrieben wuerde.
#
# Quelle: module.yaml aus einem Klon von plaintext-modules (MODULES_KLON, Vorgabe ~/plaintext-modules),
# Stand origin/master. Ziel: /volume1/docker/<app>/data/<env>/module/registry.yaml, atomar
# (temp + mv im selben Verzeichnis, wie das Jar-Staging in tui-build-logic.sh).
set -euo pipefail

APP="${1:-}"; UMGEBUNG="${2:-}"; JA="${3:-}"
NAS_HOST="${NAS_HOST:-192.100.0.1}"
DEPLOY_SERVER="${DEPLOY_SERVER:-mad@${NAS_HOST}}"
KLON="${MODULES_KLON:-$HOME/plaintext-modules}"

case "$UMGEBUNG" in int|prod) ;; *) echo "Aufruf: $0 <app> <int|prod> [--ja]" >&2; exit 2 ;; esac
[[ "$APP" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "FEHLER: App-Name '$APP' ungueltig" >&2; exit 2; }

git -C "$KLON" fetch -q origin
QUELLE="$(mktemp)"
trap 'rm -f "$QUELLE"' EXIT
git -C "$KLON" show origin/master:module.yaml > "$QUELLE"
STAND="$(git -C "$KLON" rev-parse --short origin/master)"

# Nur Format 2 (die Modul-Ansicht lehnt alles andere ab) und gueltiges YAML.
python3 - "$QUELLE" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(d, dict) or d.get("format") != 2:
    sys.exit("FEHLER: module.yaml ist nicht Format 2")
n = sum(1 for m in d.get("module", []) if m.get("art") in ("modul", "api") and m.get("versionen"))
print(f"Format 2, Huelle {d.get('zug', {}).get('root')}, {n} ladbare Module mit Version")
PY

ZIEL_DIR="/volume1/docker/${APP}/data/${UMGEBUNG}/module"
echo "Quelle: plaintext-modules@${STAND}  ->  ${DEPLOY_SERVER}:${ZIEL_DIR}/registry.yaml"
if [ "$JA" != "--ja" ]; then
    echo "Trockenlauf. Mit --ja wird geschrieben."
    exit 0
fi
# shellcheck disable=SC2029 # ZIEL_DIR wird bewusst lokal eingesetzt
ssh "$DEPLOY_SERVER" "test -d '${ZIEL_DIR}'" \
    || { echo "FEHLER: ${ZIEL_DIR} fehlt auf dem NAS (Rollout-Schritt 'PV anlegen', Karte 1516)" >&2; exit 1; }
TMP_NAME=".registry.yaml.$$.$(date +%s)"
# shellcheck disable=SC2029
ssh "$DEPLOY_SERVER" "cat > '${ZIEL_DIR}/${TMP_NAME}' && chmod 644 '${ZIEL_DIR}/${TMP_NAME}' && mv -f '${ZIEL_DIR}/${TMP_NAME}' '${ZIEL_DIR}/registry.yaml'" < "$QUELLE"
# Gegenprobe: liegt genau diese Datei dort?
LOKAL="$(sha256sum "$QUELLE" | cut -c1-64)"
# shellcheck disable=SC2029
FERN="$(ssh "$DEPLOY_SERVER" "sha256sum '${ZIEL_DIR}/registry.yaml'" | cut -c1-64)"
[ "$LOKAL" = "$FERN" ] || { echo "FEHLER: sha256 auf dem NAS ($FERN) != lokal ($LOKAL)" >&2; exit 1; }
echo "registry.yaml geschrieben (sha256 ${LOKAL:0:12}...). Wirksam in der Modul-Ansicht sofort, fuer den Lader erst nach 'Konfig schreiben' und Neustart."
