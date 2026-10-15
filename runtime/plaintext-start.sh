#!/bin/sh
# Karte 1516 (Laufzeit-Module Schritt 5): Startkommando der Huelle mit ModulLader.
#
# Nur in Gebrauch, wo Compose es ausdruecklich setzt (`command: ["plaintext-start"]`); das CMD des
# Images bleibt `java $JAVA_OPTS -jar /app/app.jar`, alle anderen Apps starten unveraendert.
#
#   1. Das Lader-Jar liegt im Exec-Jar (BOOT-INF/lib/plaintext-root-lader-*.jar, kommt mit
#      plaintext-admin-modules ab Karte 1515). Es wird nach /tmp entpackt; kein zweites
#      Deploy-Artefakt, keine Aenderung am Staging.
#   2. Start: java -cp /app/app.jar:<lader.jar> ch.plaintext.lader.ModulLader
#      Der Lader liest /data/module/module.yaml (PLAINTEXT_MODULE_VERZEICHNIS). Fehlt sie oder steht
#      NOTFALL-AUS dort, startet er wie heute (JarLauncher).
#   3. Ohne Lader im Jar (aelteres root): Warnung und `java -jar` wie bisher.
set -eu
JAR="${PLAINTEXT_APP_JAR:-/app/app.jar}"
# BusyBox-unzip kennt kein -Z1: Namen aus der Liste lesen.
LADER_NAME="$(unzip -l "$JAR" 'BOOT-INF/lib/plaintext-root-lader-*.jar' 2>/dev/null \
    | awk '$4 ~ /^BOOT-INF\/lib\/plaintext-root-lader-[^\/]*\.jar$/ {print $4; exit}' || true)"
if [ -z "$LADER_NAME" ]; then
    echo "[plaintext-start] kein plaintext-root-lader in $JAR: Start ohne Lader (java -jar)" >&2
    # shellcheck disable=SC2086 # JAVA_OPTS ist absichtlich eine Liste von Optionen
    exec java $JAVA_OPTS -jar "$JAR"
fi
LADER="$(mktemp /tmp/plaintext-root-lader.XXXXXX)"
unzip -p "$JAR" "$LADER_NAME" > "$LADER"
echo "[plaintext-start] $LADER_NAME, Modulverzeichnis ${PLAINTEXT_MODULE_VERZEICHNIS:-/data/module}" >&2
# shellcheck disable=SC2086
exec java $JAVA_OPTS -cp "$JAR:$LADER" ch.plaintext.lader.ModulLader
