#!/usr/bin/env bash
# test-retry-transient.sh — bewacht den Retry-Helfer aus Karte 1651.
#
# WORUM ES GEHT
#
# Der Release-Lauf vertrug keinen einzigen Aussetzer: GitHub-Stoerung am Tag-Push (2.2062.0)
# und HTTP 502 des Anmelde-Proxys beim Upload (2.2063.0) liessen je ein «Tag ohne Artefakte»
# zurueck, beide von Hand repariert. Der Helfer wiederholt nur VORUEBERGEHENDE Fehler
# (502/503/504, Netz-Ausfaelle) — NIE 401/403, die sind echt, und NIE harte Bau-/Testfehler.
#
# Durchsicht worker 04.11. (PR #147, Nachbesserung): Die Einordnung eines `mvn`-Fehlers
# geschieht NUR an den [ERROR]-Zeilen des Deploy (nicht am gesamten Log — Testausgaben wie
# «Tests run: 502» sind KEIN transienter Fehler), der HALB-PUBLIZIERT-Zweig bricht mit
# rc!=0 ab, und der Wiederholungs-Versuch wiederholt nur den Upload (`deploy:deploy`), nicht
# den ganzen Bau. Die Ausgabe laeuft per tee live.
#
# Aufruf:  ./test-retry-transient.sh [pfad-zu-tui-build-logic.sh]
set -uo pipefail

SKRIPT="${1:-$(dirname "$0")/tui-build-logic.sh}"
[ -r "$SKRIPT" ] || { echo "nicht lesbar: $SKRIPT" >&2; exit 2; }

FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1";
           else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi }

# Funktionskoerper per awk extrahieren (Muster: test-lokal-release.sh)
koerper() { awk "/^$1\\(\\) \\{/,/^\\}/" "$SKRIPT"; }
[ -n "$(koerper retry_transient)" ] || { echo "FEHL: retry_transient nicht in $SKRIPT gefunden"; exit 2; }
[ -n "$(koerper deploy_fehler_ist_transient)" ] || { echo "FEHL: deploy_fehler_ist_transient nicht gefunden"; exit 2; }

# Werden von der unten per eval extrahierten retry_transient genutzt (export, sonst SC2034).
export RED=''; export YELLOW=''; export NC=''

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

eval "$(koerper retry_transient)"
eval "$(koerper deploy_fehler_ist_transient)"

# Mock-Kommando: zaehlt Aufrufe in $ZAEHLER, verhaelt sich je nach Name. Meldungen mit
# Wortgrenzen um 502, damit der Zahlen-Schutz des Helfers real mitgeprueft wird.
cat > "$TMPDIR_TEST/mock.sh" <<'EOS'
#!/usr/bin/env bash
z=$(( $(cat "$ZAEHLER" 2>/dev/null || echo 0) + 1 )); echo "$z" > "$ZAEHLER"
case "$MOCK_MODUS" in
    einmal_502)
        if [ "$z" -eq 1 ]; then echo "The requested URL returned error: 502" >&2; exit 1; fi
        echo "ok"; exit 0 ;;
    dauer_502)
        echo "Proxy-Fehler: 502 Bad Gateway" >&2; exit 1 ;;
    immer_403)
        echo "403 Forbidden" >&2; exit 1 ;;
    zahl_502)
        echo "Tests run: 502, Failures: 0" >&2; exit 1 ;;
    harter_fehler)
        echo "COMPILATION ERROR: irgendwas" >&2; exit 1 ;;
esac
EOS
chmod +x "$TMPDIR_TEST/mock.sh"

aufrufe() { cat "$TMPDIR_TEST/zaehler" 2>/dev/null || echo 0; }

run_case() { # run_case <name> <modus> <erwarteter_rc> <max_aufrufe> <meldung_drin>
    local name="$1" modus="$2" wantrc="$3" maxcalls="$4" drin="$5" rc
    : > "$TMPDIR_TEST/zaehler"
    MOCK_MODUS="$modus" ZAEHLER="$TMPDIR_TEST/zaehler" RETRY_WARTE_BASE=0 \
        retry_transient "$TMPDIR_TEST/mock.sh" > "$TMPDIR_TEST/out.txt" 2>&1
    rc=$?
    pruefe "$name: rc=$wantrc" "$wantrc" "$rc"
    local calls; calls=$(aufrufe)
    if [ "$calls" -le "$maxcalls" ]; then printf '  ok   %s: %s Aufruf(e) (<= %s)\n' "$name" "$calls" "$maxcalls";
    else printf '  FEHL %s: %s Aufrufe, erwartet <= %s\n' "$name" "$calls" "$maxcalls"; FEHLER=1; fi
    if [ -n "$drin" ]; then
        if grep -q "$drin" "$TMPDIR_TEST/out.txt"; then printf '  ok   %s: Ausgabe enthält "%s"\n' "$name" "$drin";
        else printf '  FEHL %s: Ausgabe ohne "%s"\n' "$name" "$drin"; FEHLER=1; fi
    fi
}

run_logcase() { # run_logcase <name> <log-inhalt> <erwartung: transient|nicht>
    local name="$1" log="$2" want="$3" got
    printf '%b\n' "$log" > "$TMPDIR_TEST/deploy.log"
    if deploy_fehler_ist_transient "$TMPDIR_TEST/deploy.log"; then got="transient"; else got="nicht"; fi
    pruefe "$name" "$want" "$got"
}

echo "== retry_transient (Verhalten) ============================================"
run_case "einmaliger 502 -> Erfolg nach Versuch 2" einmal_502 0 3 "Versuch 2/3"
run_case "dauerhafter 502 -> gibt nach Obergrenze auf" dauer_502 1 3 "gescheitert"
run_case "401/403 -> kein Retry, sofort Abbruch" immer_403 1 1 "kein Retry"
run_case "Zahl 502 im Log -> kein Retry (Wortgrenzen)" zahl_502 1 1 ""
run_case "harter Fehler -> kein Retry" harter_fehler 1 1 ""

echo "== deploy_fehler_ist_transient (Einordnung nur an [ERROR]-Deploy-Zeilen) =="
run_logcase "Testfehler mit «Tests run: 502» -> nicht transient" \
    "[INFO] Tests run: 502, Failures: 1, Errors: 0\n[ERROR] Tests run: 502: Failures: 1: something" "nicht"
run_logcase "Compile-Fehler -> nicht transient" \
    "[ERROR] COMPILATION ERROR: symbol not found" "nicht"
run_logcase "Deploy 502 (status code) -> transient" \
    "[ERROR] Failed to deploy artifacts: Could not transfer artifact x.pom: status code: 502" "transient"
run_logcase "Deploy 503 Service Unavailable -> transient" \
    "[ERROR] Could not transfer artifact: 503 Service Unavailable" "transient"
run_logcase "Deploy 401 -> nicht transient" \
    "[ERROR] Failed to deploy: status code: 401, reason: Unauthorized" "nicht"
run_logcase "Netz-Abbruch beim Uebertragen -> transient" \
    "[ERROR] Could not transfer artifact x.jar: transfer closed with 1234 bytes remaining" "transient"

echo "== Struktur (Aufrufstellen im Release-Lauf) =============================="
grep_q() { local n; n=$(grep -c "$@") || true; [ "${n:-0}" -gt 0 ]; }
pruefe "git push mit retry_transient" "ja" "$(grep_q 'retry_transient git push;' "$SKRIPT" && echo ja || echo nein)"
pruefe "Tag-Push mit retry_transient" "ja" "$(grep_q 'retry_transient git push origin \"refs/tags/\${NEW_VERSION}\"' "$SKRIPT" && echo ja || echo nein)"
pruefe "Upload-Retry per deploy:deploy (kein Vollbau)" "ja" "$(grep_q 'retry_transient mvn deploy:deploy' "$SKRIPT" && echo ja || echo nein)"
pruefe "409-Schutz: kein Retry wenn Artefakte schon da" "ja" "$(grep_q 'kein Retry (Reposilite 409' "$SKRIPT" && echo ja || echo nein)"
pruefe "HALB PUBLIZIERT-Meldung beim Restfall" "ja" "$(grep_q 'HALB PUBLIZIERT' "$SKRIPT" && echo ja || echo nein)"
HALB_RUECKGABE=$(awk '/HALB PUBLIZIERT/{f=1} f && /return 1/{print "ja"; exit}' "$SKRIPT")
pruefe "HALB PUBLIZIERT bricht mit return 1 ab (Durchsicht worker)" "ja" "${HALB_RUECKGABE:-nein}"

echo "=========================================================================="
if [ "$FEHLER" = "0" ]; then echo "ERGEBNIS: alle Faelle wie erwartet"; else echo "ERGEBNIS: FEHLER"; exit 1; fi
