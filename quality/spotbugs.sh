#!/usr/bin/env bash
# =============================================================================
# spotbugs.sh — statische Bytecode-Analyse (SpotBugs + FindSecBugs)
# -----------------------------------------------------------------------------
# Findet Bug-Muster und Sicherheitslücken (SQLi, XSS, Path-Traversal, …) direkt
# im kompilierten Bytecode. Ergänzt CodeQL (dort nur für root aktiv) und läuft
# ohne GitHub-Advanced-Security. FindSecBugs steuert die Security-Regeln bei.
#
# Nutzung:
#   quality/spotbugs.sh <projekt-verzeichnis> [threshold]
#     threshold : Low|Medium|High (Default: Medium — meldet Medium+High)
#
# Voraussetzung: das Projekt ist gebaut (Klassen unter target/classes). Das
# Skript ruft zuvor `-DskipTests package`, damit die Analyse Bytecode hat.
# Reports: je Modul target/spotbugsXml.xml + eine aggregierte HTML unter
#          <projekt>/target/spotbugs-aggregate.html
# =============================================================================
set -euo pipefail

PROJECT_DIR="${1:?Projekt-Verzeichnis angeben}"
THRESHOLD="${2:-Medium}"
SB_VERSION="${SPOTBUGS_VERSION:-4.8.6.6}"
FSB_VERSION="${FINDSECBUGS_VERSION:-1.13.0}"

cd "$PROJECT_DIR"
if [ -x "./mvnw" ]; then MVN="./mvnw"; elif command -v mvn >/dev/null 2>&1; then MVN="mvn"; else
  echo "FEHLER: weder ./mvnw noch mvn gefunden in $PROJECT_DIR" >&2
  exit 2
fi

echo "== SpotBugs ${SB_VERSION} + FindSecBugs ${FSB_VERSION} für $(basename "$PROJECT_DIR") (Threshold: ${THRESHOLD}) =="

# Bytecode bereitstellen (ohne Tests, schnell) und SpotBugs im Security-Fokus laufen lassen.
"$MVN" -B -DskipTests package \
  com.github.spotbugs:spotbugs-maven-plugin:${SB_VERSION}:spotbugs \
  -Dspotbugs.effort=Max \
  -Dspotbugs.threshold="${THRESHOLD}" \
  -Dspotbugs.plugins=com.h3xstream.findsecbugs:findsecbugs-plugin:${FSB_VERSION} \
  -Dspotbugs.xmlOutput=true

echo "== Gefundene Bug-Instanzen je Modul =="
found=0
while IFS= read -r xml; do
  n=$(grep -c "<BugInstance" "$xml" 2>/dev/null || echo 0)
  found=$((found + n))
  [ "$n" -gt 0 ] && echo "  $n  ${xml#./}"
done < <(find . -path "*/target/spotbugsXml.xml" 2>/dev/null)
echo "SpotBugs gesamt: ${found} Bug-Instanzen (Threshold ${THRESHOLD})."
