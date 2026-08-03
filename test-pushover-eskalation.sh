#!/usr/bin/env bash
# test-pushover-eskalation.sh — Pruefung von pushover-eskalation (Karte 382, Teil 2).
#
# Es wird NIE wirklich gesendet und NIE wirklich eine Karte angelegt: sowohl das
# pushover-Werkzeug als auch das Auftragskommando werden durch Attrappen ersetzt, die ihre
# Aufrufe protokollieren. Geprueft wird das Verhalten, nicht die Fremdsysteme.
#
# Der wichtigste Fall ist der Rueckkopplungstest (Definition of Done der Karte):
# ein Vorfall darf GENAU EINEN Auftrag erzeugen, auch wenn danach weiter geprueft wird.
#
# Aufruf:  ./test-pushover-eskalation.sh [pfad-zu-pushover-eskalation]
set -uo pipefail

SKRIPT="${1:-$(dirname "$0")/pushover-eskalation}"
[ -x "$SKRIPT" ] || { echo "nicht ausfuehrbar: $SKRIPT" >&2; exit 2; }

WERKSTATT="$(mktemp -d)"
trap 'rm -rf "$WERKSTATT"' EXIT
export ESKALATION_STATE_DIR="$WERKSTATT/state"
export ESKALATION_FRIST_MIN=10
export ESKALATION_SPERRE_MIN=60
export ESKALATION_KOMMANDO="$WERKSTATT/deck-attrappe"
export PUSHOVER_CMD="$WERKSTATT/pushover-attrappe"

FEHLER=0
pruefe() { # pruefe "Beschreibung" "erwartet" "erhalten"
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi
}

# --- Attrappen ---------------------------------------------------------------
# pushover-Attrappe: gibt einen Beleg aus; QUITTIERT steuert den Exit-Code von --quittiert.
cat > "$WERKSTATT/pushover-attrappe" <<'ATT'
#!/usr/bin/env bash
if [ "${1:-}" = "--quittiert" ]; then
    echo "$2" >> "$WERKSTATT_LOG/abfragen"
    [ "${QUITTIERT:-nein}" = "ja" ] && exit 0 || exit 4
fi
echo "senden $*" >> "$WERKSTATT_LOG/sendungen"
echo "beleg-${RANDOM}"
ATT
chmod +x "$WERKSTATT/pushover-attrappe"

cat > "$WERKSTATT/deck-attrappe" <<'ATT'
#!/usr/bin/env bash
# Erwartet: deck new <stack> <titel> <prio> --file -
{ echo "AUFTRAG stack=$2 titel=$3"; cat; } >> "$WERKSTATT_LOG/auftraege"
ATT
chmod +x "$WERKSTATT/deck-attrappe"

export WERKSTATT_LOG="$WERKSTATT/log"; mkdir -p "$WERKSTATT_LOG"
: > "$WERKSTATT_LOG/sendungen"; : > "$WERKSTATT_LOG/auftraege"; : > "$WERKSTATT_LOG/abfragen"

# Setzt das Alter eines Vorgangs kuenstlich hoch, damit die Frist ohne Warten greift.
altern() { # altern <schluessel> <minuten>
    local d="$ESKALATION_STATE_DIR/$1.vorgang"
    sed -i "1s/.*/$(( $(date +%s) - $2 * 60 ))/" "$d"
}

echo "== Melden ================================================================="
AUSGABE="$("$SKRIPT" melde "PROD-Web down" "Monitor meldet 502 seit 3 Minuten." "prod-web" 2>&1)"
pruefe "melde liefert einen Beleg-Schluessel" "ja" "$([ -n "$AUSGABE" ] && echo ja || echo nein)"
pruefe "genau eine Sendung" "1" "$(wc -l < "$WERKSTATT_LOG/sendungen")"
pruefe "mit Emergency-Prioritaet" "ja" "$(grep -q -- "-p 2" "$WERKSTATT_LOG/sendungen" && echo ja || echo nein)"
pruefe "Vorgang angelegt und offen" "offen" "$(sed -n '3p' "$ESKALATION_STATE_DIR/prod-web.vorgang" 2>/dev/null)"

echo "== Zweiter Alarm zum selben Vorfall ======================================="
"$SKRIPT" melde "PROD-Web down" "Nochmal dasselbe." "prod-web" >/dev/null 2>&1
pruefe "kein zweiter Emergency zum offenen Vorgang" "1" "$(wc -l < "$WERKSTATT_LOG/sendungen")"

echo "== Pruefen vor Ablauf der Frist ==========================================="
"$SKRIPT" pruefen >/dev/null 2>&1
pruefe "vor der Frist kein Auftrag" "0" "$(grep -c AUFTRAG "$WERKSTATT_LOG/auftraege")"
pruefe "Vorgang weiterhin offen" "offen" "$(sed -n '3p' "$ESKALATION_STATE_DIR/prod-web.vorgang")"

echo "== Pruefen nach Ablauf der Frist =========================================="
altern prod-web 11
"$SKRIPT" pruefen >/dev/null 2>&1
pruefe "genau ein Auftrag" "1" "$(grep -c AUFTRAG "$WERKSTATT_LOG/auftraege")"
pruefe "Auftrag geht nach todo" "ja" "$(grep -q 'stack=todo' "$WERKSTATT_LOG/auftraege" && echo ja || echo nein)"
pruefe "Vorgang als eskaliert markiert" "eskaliert" "$(sed -n '3p' "$ESKALATION_STATE_DIR/prod-web.vorgang")"
pruefe "Auftrag nennt die Crashloop-Grenze" "ja" "$(grep -q 'drittes Mal' "$WERKSTATT_LOG/auftraege" && echo ja || echo nein)"
pruefe "Auftrag verbietet Deploys" "ja" "$(grep -qi 'Nicht erlaubt.*Deploys' "$WERKSTATT_LOG/auftraege" && echo ja || echo nein)"

echo "== RUECKKOPPLUNGSTEST (Definition of Done) ================================"
# Die Sitzung reagiert auf den Auftrag, startet etwas neu, der Dienst wackelt erneut —
# und der Cron laeuft weiter. Es darf KEIN zweiter Auftrag entstehen.
for _ in 1 2 3; do "$SKRIPT" pruefen >/dev/null 2>&1; done
pruefe "auch nach drei weiteren Laeufen genau EIN Auftrag" "1" "$(grep -c AUFTRAG "$WERKSTATT_LOG/auftraege")"
"$SKRIPT" melde "PROD-Web down" "Der Dienst wackelt erneut." "prod-web" >/dev/null 2>&1
pruefe "erneuter Alarm in der Sperrzeit sendet nicht" "1" "$(wc -l < "$WERKSTATT_LOG/sendungen")"
pruefe "und erzeugt keinen zweiten Auftrag" "1" "$(grep -c AUFTRAG "$WERKSTATT_LOG/auftraege")"

echo "== Entwarnung gibt den Vorfall wieder frei ================================"
"$SKRIPT" ende prod-web >/dev/null 2>&1
pruefe "Vorgang nach Entwarnung entfernt" "nein" "$([ -f "$ESKALATION_STATE_DIR/prod-web.vorgang" ] && echo ja || echo nein)"
"$SKRIPT" melde "PROD-Web down" "Neuer Vorfall nach Entwarnung." "prod-web" >/dev/null 2>&1
pruefe "nach Entwarnung wird wieder gesendet" "2" "$(wc -l < "$WERKSTATT_LOG/sendungen")"

echo "== Quittierter Alarm eskaliert nicht ======================================"
: > "$WERKSTATT_LOG/auftraege"
altern prod-web 30
QUITTIERT=ja "$SKRIPT" pruefen >/dev/null 2>&1
pruefe "quittiert -> kein Auftrag" "0" "$(grep -c AUFTRAG "$WERKSTATT_LOG/auftraege")"
pruefe "Vorgang als quittiert markiert" "quittiert" "$(sed -n '3p' "$ESKALATION_STATE_DIR/prod-web.vorgang")"

echo "== Auffangweg, wenn das Board nicht erreichbar ist ========================"
"$SKRIPT" ende prod-web >/dev/null 2>&1
"$SKRIPT" melde "DB weg" "Postgres antwortet nicht." "prod-db" >/dev/null 2>&1
altern prod-db 15
ESKALATION_KOMMANDO="/nicht/vorhanden" "$SKRIPT" pruefen >/dev/null 2>&1
pruefe "Auftrag landet als Datei statt verloren zu gehen" "ja" \
    "$(ls "$ESKALATION_STATE_DIR"/auftrag-prod-db-*.md >/dev/null 2>&1 && echo ja || echo nein)"

echo "== Aufruffehler ==========================================================="
"$SKRIPT" melde "" "" >/dev/null 2>&1; pruefe "melde ohne Titel/Text abgewiesen" "2" "$?"
"$SKRIPT" >/dev/null 2>&1; pruefe "ohne Unterbefehl abgewiesen" "2" "$?"

echo
if [ "$FEHLER" = "0" ]; then echo "ERGEBNIS: alle Faelle wie erwartet"; else echo "ERGEBNIS: FEHLER"; fi
exit "$FEHLER"
