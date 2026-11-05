#!/usr/bin/env bash
# test-retry-upload-nachversuch.sh — Karte 1651 (Rueckgabe der Abnahme, Auftrag worker):
# Die echte Nachversuch-Stelle aus tui-build-logic.sh — der Block «RETRY (1 von 1)» in
# do_release_bauen_und_veroeffentlichen — laeuft NICHT nur als Text, sondern ausgefuehrt:
# Funktion und deploy_fehler_ist_transient werden aus dem Skript extrahiert und gegen den
# Mini-Server gefahren. Szenario: erster Upload-Versuch bekommt HTTP 502, der Nachversuch
# laedt erfolgreich hoch — der Lauf endet gruen, die Wiederholung steht im Log.
# Code wird nur angefasst, wenn dieser Test einen Fehler zeigt.
set -uo pipefail

SKRIPT="${1:-$(dirname "$0")/tui-build-logic.sh}"
[ -r "$SKRIPT" ] || { echo "nicht lesbar: $SKRIPT" >&2; exit 2; }

FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1";
           else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi }

# In der extrahierten Funktion genutzte Farbvariablen (im Test ohne Wirkung, aber gesetzt wegen set -u).
# shellcheck disable=SC2034  # werden in der zur Laufzeit extrahierten Funktion genutzt
BLUE=""; GREEN=""; RED=""; YELLOW=""; NC=""

# release_vollstaendig_pruefen ist nicht Gegenstand dieses Tests -> no-op
release_vollstaendig_pruefen() { return 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

# Die echten Funktionen aus dem Skript schneiden und laden (Muster test-versionsschritt.sh).
FUNCS="$WORK/funktionen.sh"
sed -n '/^deploy_fehler_ist_transient() {/,/^}/p' "$SKRIPT" > "$FUNCS"
sed -n '/^do_release_bauen_und_veroeffentlichen() {/,/^}/p' "$SKRIPT" >> "$FUNCS"
grep -q "do_release_bauen_und_veroeffentlichen" "$FUNCS" \
    || { echo "FEHL: Funktion do_release_bauen_und_veroeffentlichen nicht in $SKRIPT gefunden"; exit 2; }
grep -q "RETRY (1 von 1)" "$FUNCS" \
    || { echo "FEHL: Nachversuch-Block fehlt in der extrahierten Funktion"; exit 2; }
# Nach der Erfolgsmeldung sofort beenden: Der Rest der Funktion (else-Zweig,
# release_vollstaendig_pruefen, JAR-Volume-Deploy) ist nicht Gegenstand dieser Pruefung.
# return 0 genuegt — die offenen if-Strukturen bleiben syntaktisch stehen (unreachable).
python3 - "$FUNCS" <<'PYEOF'
import sys
p = sys.argv[1]
out = []
for ln in open(p, encoding="utf-8").read().splitlines():
    out.append(ln)
    if "Retry erfolgreich" in ln:
        out.append("            return 0  # Test-Hook: Nachversuch geprueft, Rest unerreichbar")
open(p, "w", encoding="utf-8").write("\n".join(out) + "\n")
PYEOF
# shellcheck disable=SC1090  # $FUNCS entsteht zur Laufzeit aus dem zu pruefenden Skript
. "$FUNCS"

# ── Mini-Server: erster PUT -> 502, alle weiteren -> 200 ──────────────────────
cat > "$WORK/server.py" <<'PY'
import http.server

zaehl_datei = __import__("sys").argv[1]

class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0) or 0))
        try:
            n = int(open(zaehl_datei).read().strip() or 0)
        except Exception:
            n = 0
        n += 1
        with open(zaehl_datei, "w") as f:
            f.write(str(n))
        if n == 1:
            self.send_response(502); self.send_header("Content-Length", "0"); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
    def do_GET(self):
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
    def do_HEAD(self):
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a):
        pass

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY

# ── Mini-Projekt (Muster test-retry-upload-mini.sh) ───────────────────────────
mkdir -p "$WORK/proj/src/main/java"
cat > "$WORK/proj/pom.xml" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>ch.plaintext.test</groupId>
  <artifactId>retry-nachversuch</artifactId>
  <version>1.0</version>
  <packaging>jar</packaging>
  <properties><maven.compiler.release>17</maven.compiler.release></properties>
  <distributionManagement>
    <repository><id>mini</id><url>http://127.0.0.1:PORT/repo</url></repository>
  </distributionManagement>
</project>
POM
cp "$WORK/proj/pom.xml" "$WORK/proj/pom.xml.template"

: > "$WORK/puts"
python3 "$WORK/server.py" "$WORK/puts" > "$WORK/port.txt" 2>/dev/null &
SERVER_PID=$!
for _ in $(seq 1 50); do [ -s "$WORK/port.txt" ] && break; sleep 0.1; done
port=$(head -1 "$WORK/port.txt")
sed "s/PORT/$port/" "$WORK/proj/pom.xml.template" > "$WORK/proj/pom.xml"

# ── Szenario: Erstversuch 502 -> transient erkannt -> genau ein Nachversuch, gruen ──
# RELEASE_UPLOAD_RETRY_WAIT=0: kein Schlaf im Test; REL_URL leer: HALB-PUBLIZIERT-Zweig ist
# hier nicht Gegenstand (wird an Reposilite-409-Logik gemessen, nicht am Mini-Server).
(
    cd "$WORK/proj" || exit 1
    export MVN_RELEASE_DEPLOY=true MVN_TEST_FLAG=-DskipTests MVN_UPLOAD_RETRY=3
    export RELEASE_UPLOAD_RETRY=true RELEASE_UPLOAD_RETRY_WAIT=0
    export NEW_VERSION=1.0 REL_URL=""
    do_release_bauen_und_veroeffentlichen
) > "$WORK/lauf.log" 2>&1
rc=$?
kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""
puts=$(cat "$WORK/puts" 2>/dev/null || echo 0)

echo "== Echter Nachversuch: 502 beim Erstversuch, dann Erfolg (aus tui-build-logic.sh) =="
pruefe "Lauf endet erfolgreich (exit 0)" "0" "$rc"
if grep -q "RETRY (1 von 1)" "$WORK/lauf.log"; then printf '  ok   Wiederholung im Log: RETRY (1 von 1)\n';
else printf '  FEHL Wiederholung fehlt im Log (%s)\n' "$WORK/lauf.log"; FEHLER=1; fi
if grep -q "Retry erfolgreich" "$WORK/lauf.log"; then printf '  ok   Erfolgsmeldung nach dem Retry\n';
else printf '  FEHL Erfolgsmeldung fehlt im Log\n'; FEHLER=1; fi
if [ "$puts" -ge 2 ]; then printf '  ok   PUTs: %s (mind. Fehl-PUT + Erfolg)\n' "$puts";
else printf '  FEHL PUTs: %s (erwartet >= 2)\n' "$puts"; FEHLER=1; fi

echo "=========================================================================="
if [ "$FEHLER" = "0" ]; then echo "ERGEBNIS: Nachversuch laeuft wie verlangt"; else echo "ERGEBNIS: FEHLER (Log: $WORK/lauf.log wird mit -x geprueft)"; exit 1; fi
