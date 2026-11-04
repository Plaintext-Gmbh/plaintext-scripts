#!/usr/bin/env bash
# test-retry-upload-mini.sh — beweist am echten Mini-Projekt, dass Maven den Upload-PUT
# selbst wiederholt, wenn es die Retry-Flags bekommt (Karte 1651, Durchsicht worker
# 04.11.: Mock-Tests sehen den Unterschied nicht, Beleg am echten Mini-Projekt verlangt).
#
# Der Shell-Retry um `mvn clean deploy` wurde nach der Durchsicht verworfen:
#   - `mvn deploy:deploy` allein scheitert ("did not assign a file to the build artifact").
#   - `if ! mvn ... | tee` prueft tee statt mvn (PIPESTATUS-Problem), ohne pipefail lief ein
#     gescheiterter Deploy als Erfolg weiter.
# Stattdessen bekommt Maven die Retry-Flags und wiederholt den PUT selbst:
#   -Daether.connector.http.retryHandler.count=3   (Maven-Resolver, Maven 3.9+)
#   -Dmaven.wagon.http.retryHandler.count=3         (Wagon-Transport)
#
# Dieser Test deployt ein echtes Mini-Projekt gegen einen lokalen Python-Server, der die
# PUTs zaehlt (Datei) und die ersten mit Fehlerstatus beantwortet. Gemessen wird der
# Prozess-Exit UND die PUT-Anzahl — so ist sichtbar: wiederholt Maven (>=2 PUTs beim
# einmaligen 502), gibt er bei 401 sofort auf (genau 1 PUT), und ist die Obergrenze da.
#
# Aufruf:  ./test-retry-upload-mini.sh [pfad-zu-tui-build-logic.sh]
set -uo pipefail

SKRIPT="${1:-$(dirname "$0")/tui-build-logic.sh}"
[ -r "$SKRIPT" ] || { echo "nicht lesbar: $SKRIPT" >&2; exit 2; }

FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1";
           else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi }
grep_q() { local n; n=$(grep -c "$@" "$SKRIPT") || true; [ "${n:-0}" -gt 0 ]; }

grep_q 'aether.connector.http.retryHandler.count' || { echo "FEHL: aether-Retry-Flag fehlt in $SKRIPT"; exit 2; }
grep_q 'maven.wagon.http.retryHandler.count' || { echo "FEHL: wagon-Retry-Flag fehlt in $SKRIPT"; exit 2; }
command -v mvn >/dev/null || { echo "FEHL: mvn nicht im Pfad"; exit 2; }
command -v python3 >/dev/null || { echo "FEHL: python3 nicht im Pfad"; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

# ── Fauler Server: zaehlt PUTs in eine Datei, antwortet mit Fehlerstatus ──────
cat > "$WORK/server.py" <<'PY'
import http.server, sys, socket

modus, zaehl_datei = sys.argv[1], sys.argv[2]

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
        if modus == "abriss" and n == 1:
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if modus == "einmal502" and n == 1:
            self.send_response(502); self.send_header("Content-Length", "0"); self.end_headers(); return
        if modus == "dauer502":
            self.send_response(502); self.send_header("Content-Length", "0"); self.end_headers(); return
        if modus == "immer401":
            self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers(); return
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

# ── Mini-Projekt: leere Jar (maven-jar-plugin baut sie, nur eine Warnung) ─────
mkdir -p "$WORK/proj/src/main/java"
cat > "$WORK/proj/pom.xml" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>ch.plaintext.test</groupId>
  <artifactId>retry-mini</artifactId>
  <version>1.0</version>
  <packaging>jar</packaging>
  <properties><maven.compiler.release>17</maven.compiler.release></properties>
  <distributionManagement>
    <repository><id>mini</id><url>http://127.0.0.1:PORT/repo</url></repository>
  </distributionManagement>
</project>
POM
cp "$WORK/proj/pom.xml" "$WORK/proj/pom.xml.template"

szenario() { # szenario <name> <modus> <erwartung: ok|abbruch> <puts_min> <puts_max>
    local name="$1" modus="$2" want="$3" pmin="$4" pmax="$5" rc puts port
    : > "$WORK/puts"
    python3 "$WORK/server.py" "$modus" "$WORK/puts" > "$WORK/port.txt" 2>/dev/null &
    SERVER_PID=$!
    for _ in $(seq 1 50); do [ -s "$WORK/port.txt" ] && break; sleep 0.1; done
    port=$(head -1 "$WORK/port.txt")
    sed "s/PORT/$port/" "$WORK/proj/pom.xml.template" > "$WORK/proj/pom.xml"
    ( cd "$WORK/proj" && timeout 180 mvn -B -q clean deploy \
        -Daether.connector.http.retryHandler.count=3 \
        -Dmaven.wagon.http.retryHandler.count=3 ) > "$WORK/mvn-$modus.log" 2>&1
    rc=$?
    kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""
    puts=$(cat "$WORK/puts" 2>/dev/null || echo 0)
    if [ "$want" = "ok" ]; then
        pruefe "$name: exit 0" "0" "$rc"
    else
        if [ "$rc" -ne 0 ]; then printf '  ok   %s: Abbruch (exit %s)\n' "$name" "$rc"; else printf '  FEHL %s: erwartet Abbruch, exit war 0\n' "$name"; FEHLER=1; fi
    fi
    if [ "$puts" -ge "$pmin" ] && [ "$puts" -le "$pmax" ]; then
        printf '  ok   %s: %s PUT(s) (erwartet %s..%s)\n' "$name" "$puts" "$pmin" "$pmax"
    else
        printf '  FEHL %s: %s PUT(s), erwartet %s..%s — mvn-Log: %s\n' "$name" "$puts" "$pmin" "$pmax" "$WORK/mvn-$modus.log"; FEHLER=1
    fi
}

echo "== Echter Mini-Deploy: was die Flags leisten (Maven 3.9, gemessen) ========"
szenario "A: Verbindungsabruch -> Flags greifen, Deploy gruen" abriss ok 2 12
szenario "B: einmaliger 502 (Response) -> bleibt FATAL, Flags greifen nicht" einmal502 abbruch 2 5
szenario "C: 401 -> sofortiger Abbruch, kein gleicher PUT zweimal" immer401 abbruch 1 2
szenario "D: dauerhafter 502 -> Abbruch mit Obergrenze" dauer502 abbruch 2 6

echo "=========================================================================="
if [ "$FEHLER" = "0" ]; then echo "ERGEBNIS: alle Faelle wie erwartet"; else echo "ERGEBNIS: FEHLER"; exit 1; fi
