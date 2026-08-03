#!/usr/bin/env bash
# Testharnisch für ./pushover (Karte 382).
#
# Prüft das Verhalten mit gemocktem curl — es wird nie wirklich gesendet. Damit ist der Test
# überall lauffähig (Runner, NAS, Entwicklungsrechner) und verbraucht kein Pushover-Kontingent.
#
# Aufruf:  ./test-pushover.sh [pfad-zu-pushover]
SKRIPT="$(readlink -f "${1:-$(dirname "$0")/pushover}" 2>/dev/null)"
[ -n "$SKRIPT" ] && [ -x "$SKRIPT" ] || { echo "pushover nicht gefunden/ausfuehrbar: ${1:-}"; exit 2; }

ARBEIT="$(mktemp -d)"; trap 'rm -rf "$ARBEIT"' EXIT
MOCK="$ARBEIT/bin"; mkdir -p "$MOCK"
FEHLER=0

# curl-Attrappe: schreibt die Aufrufargumente mit und antwortet je nach MODUS.
mock_curl() {
    cat > "$MOCK/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$ARBEIT/curl-args.txt"
case "\${MODUS:-ok}" in
  ok)          echo '{"status":1,"request":"abc"}' ;;
  emergency)   echo '{"status":1,"request":"abc","receipt":"RCPT123"}' ;;
  fehler)      echo '{"status":0,"errors":["application token is invalid"]}' ;;
  quittiert)   echo '{"status":1,"acknowledged":1,"acknowledged_at":1785700000,"expired":0}' ;;
  offen)       echo '{"status":1,"acknowledged":0,"acknowledged_at":0,"expired":0}' ;;
  abgelaufen)  echo '{"status":1,"acknowledged":0,"expired":1}' ;;
  netzfehler)  exit 7 ;;
esac
EOF
    chmod +x "$MOCK/curl"
}

lauf() {   # $1=MODUS, Rest = Argumente an pushover
    local modus="$1"; shift
    : > "$ARBEIT/curl-args.txt"
    AUSGABE="$(cd "$ARBEIT" && PATH="$MOCK:$PATH" MODUS="$modus" \
        PUSHOVER_APP_TOKEN=GEHEIMTOKEN42 PUSHOVER_USER_KEY=GEHEIMUSER42 "$SKRIPT" "$@" 2>&1)"
    RC=$?
}

pruefe() {  # $1=Beschreibung $2=erwarteter rc $3=erwarteter Text ("!"=darf nicht vorkommen, ""=egal)
    local ok=ja
    [ "$RC" = "$2" ] || ok=nein
    if [ -n "${3:-}" ]; then
        if [ "${3:0:1}" = "!" ]; then grep -qF -- "${3:1}" <<<"$AUSGABE" && ok=nein
        else grep -qF -- "$3" <<<"$AUSGABE" || ok=nein; fi
    fi
    if [ "$ok" = ja ]; then echo "  ok   $1 (rc=$RC)"
    else echo "  FEHL $1 (rc=$RC, erwartet $2)"; echo "$AUSGABE" | sed 's/^/       | /'; FEHLER=$((FEHLER+1)); fi
}

mock_curl
echo "== Senden =================================================================="
lauf ok "Testmeldung"
pruefe "normale Meldung geht raus" 0 ""
grep -q "priority=0" "$ARBEIT/curl-args.txt" && echo "  ok   Prioritaet 0 als Vorgabe" || { echo "  FEHL Prioritaet"; FEHLER=$((FEHLER+1)); }

lauf ok -p 1 -t "Titel" "Meldung"
pruefe "Prioritaet und Titel werden uebernommen" 0 ""
grep -q "priority=1" "$ARBEIT/curl-args.txt" && grep -q "title=Titel" "$ARBEIT/curl-args.txt" \
    && echo "  ok   priority=1 und title=Titel im Aufruf" || { echo "  FEHL Parameter"; FEHLER=$((FEHLER+1)); }

echo "== Emergency: retry/expire und Beleg-Schluessel ============================"
lauf emergency -p 2 "Notfall"
pruefe "Beleg-Schluessel wird ausgegeben" 0 "RCPT123"
grep -q "retry=" "$ARBEIT/curl-args.txt" && grep -q "expire=" "$ARBEIT/curl-args.txt" \
    && echo "  ok   retry und expire nur bei Prioritaet 2" || { echo "  FEHL retry/expire"; FEHLER=$((FEHLER+1)); }

lauf ok -p 1 "kein Notfall"
grep -q "retry=" "$ARBEIT/curl-args.txt" && { echo "  FEHL retry auch ohne Emergency"; FEHLER=$((FEHLER+1)); } \
    || echo "  ok   kein retry bei Prioritaet < 2"

lauf emergency -p 2 -r "$ARBEIT/receipt.txt" "Notfall mit Datei"
if [ -f "$ARBEIT/receipt.txt" ] && grep -q RCPT123 "$ARBEIT/receipt.txt"; then
    echo "  ok   Beleg-Schluessel in Datei geschrieben"
else echo "  FEHL Beleg-Datei"; FEHLER=$((FEHLER+1)); fi

echo "== Fehlerfaelle ============================================================"
lauf fehler "Meldung"
pruefe "Pushover-Fehler wird gemeldet" 3 "application token is invalid"
lauf netzfehler "Meldung"
pruefe "Netzfehler wird gemeldet" 3 "Senden fehlgeschlagen"
lauf ok -p 9 "Meldung"
pruefe "unzulaessige Prioritaet abgewiesen" 2 "zwischen -2 und 2"
lauf ok
pruefe "leere Nachricht abgewiesen" 2 "keine Nachricht"

echo "== Ohne Konfiguration ======================================================"
AUSGABE="$(cd "$ARBEIT" && PATH="$MOCK:$PATH" env -u PUSHOVER_APP_TOKEN -u PUSHOVER_USER_KEY \
    PUSHOVER_CONFIG=/nonexistent HOME="$ARBEIT/leer" "$SKRIPT" "Meldung" 2>&1)"; RC=$?
pruefe "ohne Token sauberer Abbruch" 1 "kein Token gefunden"

echo "== Quittierungsabfrage ====================================================="
lauf quittiert --quittiert RCPT123
pruefe "quittiert wird erkannt" 0 "quittiert"
lauf offen --quittiert RCPT123
pruefe "offen wird als nicht quittiert gemeldet" 4 "noch nicht quittiert"
lauf abgelaufen --quittiert RCPT123
pruefe "abgelaufen wird erkannt" 4 "abgelaufen"

echo "== Kein Geheimnis in der Ausgabe ==========================================="
lauf fehler "Meldung"
pruefe "Token erscheint nicht in der Fehlerausgabe" 3 "!GEHEIMTOKEN42"

echo
[ "$FEHLER" = 0 ] && echo "ERGEBNIS: alle Faelle wie erwartet" || echo "ERGEBNIS: $FEHLER Abweichung(en)"
exit "$FEHLER"
