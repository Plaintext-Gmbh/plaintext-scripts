#!/usr/bin/env bash
# test-registry-warte.sh — bewacht die Registry-Index-Warte aus Karte 1646.
#
# WORUM ES GEHT
#
# Der Tag-Lauf schreibt den Registry-Index parallel zum Deploy. Startete der Slot vor dem
# Upload, lief er bis zum naechsten Start im Rueckfall (RUECKFALL-MODULE-YAML). Die Warte
# prueft im aktiven Slot per wget, ob die Kopfzeile des Index «zuletzt <VERSION>» traegt,
# und startet nach der Obergrenze trotzdem (der Rueckfall laedt die richtigen Module).
#
# Der Test ersetzt ssh durch ein Mock (das Ergebnis kommt aus dem «Slot») und prueft:
# Treffer, Nicht-Treffer, Versions-Prafix (1.62 darf nicht als 1.629.0 gelten), Abruffehler,
# die Schleife mit spaetem Erscheinen und die Obergrenze mit trotzdem-Start (rc 0).
#
# Aufruf:  ./test-registry-warte.sh [pfad-zu-tui-build-logic.sh]
set -uo pipefail

SKRIPT="${1:-$(dirname "$0")/tui-build-logic.sh}"
[ -r "$SKRIPT" ] || { echo "nicht lesbar: $SKRIPT" >&2; exit 2; }

FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1";
           else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi }

# Funktionskoerper per awk extrahieren (Muster: test-lokal-release.sh / test-retry-transient.sh)
koerper() { awk "/^$1\\(\\) \\{/,/^\\}/" "$SKRIPT"; }
for FUNKTION in registry_index_hat_version warte_auf_registry_index; do
    [ -n "$(koerper "$FUNKTION")" ] || { echo "FEHL: $FUNKTION nicht in $SKRIPT gefunden"; exit 2; }
done

export GREEN='' YELLOW='' RED='' NC=''
export IMAGE_NAME="plaintext-guild" DEPLOY_SERVER="mockserver"
export REGISTRY_WARTE_MAX_SEC=2
export REGISTRY_WARTE_INTERVALL_SEC=1

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

eval "$(koerper registry_index_hat_version)"
eval "$(koerper warte_auf_registry_index)"

# Mock-ssh: zaehlt Aufrufe, gibt je nach MOCK_MODUS den Index des «Slots» aus.
cat > "$TMPDIR_TEST/ssh" <<'EOS'
#!/usr/bin/env bash
z=$(( $(cat "$ZAEHLER" 2>/dev/null || echo 0) + 1 )); echo "$z" > "$ZAEHLER"
case "$MOCK_MODUS" in
    vorhanden)  printf '# plaintext-guild: erzeugt von .woodpecker/registry.sh, zuletzt 1.629.0\nmodul x 1.629.0\n' ;;
    alt)        printf '# plaintext-guild: erzeugt von .woodpecker/registry.sh, zuletzt 1.628.0\n' ;;
    fehler)     exit 1 ;;
    spaeter)    if [ "$z" -ge 3 ]; then printf '# …, zuletzt 1.629.0\n'; else printf '# …, zuletzt 1.628.0\n'; fi ;;
esac
EOS
chmod +x "$TMPDIR_TEST/ssh"
export PATH="$TMPDIR_TEST:$PATH"
export ZAEHLER="$TMPDIR_TEST/zaehler"

echo "registry_index_hat_version:"
export MOCK_MODUS=vorhanden
registry_index_hat_version "1.629.0" "green"; pruefe "Version im Index -> rc 0" "0" "$?"
registry_index_hat_version "1.628.0" "green"; pruefe "andere Version -> rc 1" "1" "$?"
registry_index_hat_version "1.62" "green";     pruefe "Versions-Prafix 1.62 zaehlt nicht als 1.629.0 -> rc 1" "1" "$?"

export MOCK_MODUS=fehler
registry_index_hat_version "1.629.0" "green"; pruefe "Abruffehler -> rc 1" "1" "$?"

echo "warte_auf_registry_index (MAX=2s, Intervall=1s):"
MOCK_MODUS=vorhanden
AUSGABE=$(warte_auf_registry_index "1.629.0" "green"); pruefe "sofortiger Treffer -> rc 0" "0" "$?"
pruefe "Meldung nennt «bereits»" "ja" "$(grep -q 'bereits' <<<"$AUSGABE" && echo ja || echo nein)"

export MOCK_MODUS=spaeter
echo 0 > "$ZAEHLER"
AUSGABE=$(warte_auf_registry_index "1.629.0" "green"); pruefe "Version erscheint spaeter -> rc 0" "0" "$?"
pruefe "Meldung nennt die Wartezeit" "ja" "$(grep -q 'nach 2s' <<<"$AUSGABE" && echo ja || echo nein)"

export MOCK_MODUS=alt
echo 0 > "$ZAEHLER"
AUSGABE=$(warte_auf_registry_index "1.629.0" "green"); pruefe "Version kommt nie -> trotzdem rc 0" "0" "$?"
pruefe "Warnung «starte trotzdem»" "ja" "$(grep -q 'starte trotzdem' <<<"$AUSGABE" && echo ja || echo nein)"

if [ "$FEHLER" -eq 0 ]; then echo "ALLE TESTS BESTANDEN"; else echo "TESTS FEHLGESCHLAGEN"; exit 1; fi
