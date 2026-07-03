#!/usr/bin/env bash
# =============================================================================
# owasp-dependency-check.sh — CVE-Scan der Maven-Abhängigkeiten (OWASP)
# -----------------------------------------------------------------------------
# Scannt alle Dependencies eines Plaintext-Projekts gegen die NVD-CVE-Datenbank
# und schreibt HTML+JSON-Reports. Kein Eingriff in die pom.xml nötig — das Plugin
# wird per Koordinate aufgerufen. Läuft überall, wo Maven verfügbar ist (CI oder
# Dev-Maschine); die Linux-Box selbst hat kein lokales Maven.
#
# Nutzung:
#   quality/owasp-dependency-check.sh <projekt-verzeichnis> [fail-cvss]
#     projekt-verzeichnis : Wurzel eines Projekts (mit pom.xml oder mvnw)
#     fail-cvss           : optional; CVSS-Schwelle, ab der Exit!=0 (Default: 0 = nie failen)
#
# NVD-API-Key (dringend empfohlen, sonst Rate-Limit/langsam):
#   export NVD_API_KEY=<key>   (kostenlos: https://nvd.nist.gov/developers/request-an-api-key)
#
# Reports: <projekt>/target/dependency-check-report.{html,json}
# =============================================================================
set -euo pipefail

PROJECT_DIR="${1:?Projekt-Verzeichnis angeben}"
FAIL_CVSS="${2:-0}"
# Version des Plugins zentral pflegbar (Renovate-freundlich über diese Zeile).
DC_VERSION="${OWASP_DC_VERSION:-10.0.4}"

cd "$PROJECT_DIR"

# Maven-Runner ermitteln (Wrapper bevorzugt).
if [ -x "./mvnw" ]; then MVN="./mvnw"; elif command -v mvn >/dev/null 2>&1; then MVN="mvn"; else
  echo "FEHLER: weder ./mvnw noch mvn gefunden in $PROJECT_DIR" >&2
  exit 2
fi

EXTRA_ARGS=()
if [ -n "${NVD_API_KEY:-}" ]; then
  EXTRA_ARGS+=("-DnvdApiKey=${NVD_API_KEY}")
else
  echo "WARNUNG: kein NVD_API_KEY gesetzt — Scan ist langsam und ggf. rate-limited." >&2
fi
# Persistenter NVD-Cache (self-hosted Runner): Erst-Lauf lädt die NVD, danach inkrementell/schnell.
if [ -n "${OWASP_DATA_DIR:-}" ]; then
  mkdir -p "$OWASP_DATA_DIR"
  EXTRA_ARGS+=("-DdataDirectory=${OWASP_DATA_DIR}")
fi
# Suppression-Datei nur mitgeben, wenn gesetzt (leerer Wert würde DC stören).
if [ -n "${OWASP_SUPPRESSION:-}" ]; then
  EXTRA_ARGS+=("-DsuppressionFile=${OWASP_SUPPRESSION}")
fi

echo "== OWASP Dependency-Check ${DC_VERSION} für $(basename "$PROJECT_DIR") =="
"$MVN" -B org.owasp:dependency-check-maven:${DC_VERSION}:aggregate \
  -DfailBuildOnCVSS="${FAIL_CVSS}" \
  -Dformats=HTML,JSON \
  "${EXTRA_ARGS[@]}"

echo "Report: $PROJECT_DIR/target/dependency-check-report.html"
