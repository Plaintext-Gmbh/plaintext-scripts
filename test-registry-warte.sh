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
for FUNKTION in registry_indizes_im_slot registry_index_hat_version registry_quelle_ist_modules warte_auf_registry_index; do
    [ -n "$(koerper "$FUNKTION")" ] || { echo "FEHL: $FUNKTION nicht in $SKRIPT gefunden"; exit 2; }
done

export GREEN='' YELLOW='' RED='' NC=''
export IMAGE_NAME="plaintext-guild" DEPLOY_SERVER="mockserver"
export REGISTRY_WARTE_MAX_SEC=2
export REGISTRY_WARTE_MODULES_MAX_SEC=2
export REGISTRY_WARTE_INTERVALL_SEC=1

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

for FUNKTION in registry_indizes_im_slot registry_index_hat_version registry_quelle_ist_modules warte_auf_registry_index; do
    eval "$(koerper "$FUNKTION")"
done

# Mock-ssh: zaehlt Aufrufe, gibt je nach MOCK_MODUS den Index des «Slots» aus.
# Karte 2389: Die Quellen-Abfrage (grep '^registry ' ohne -i) antwortet je nach MOCK_QUELLE; der Index-
# Abruf (docker exec -i … sh mit Skript auf stdin) zaehlt und liefert je nach MOCK_MODUS.
cat > "$TMPDIR_TEST/ssh" <<'EOS'
#!/usr/bin/env bash
if [[ "$*" == *"grep '^registry '"* ]]; then
    case "${MOCK_QUELLE:-nextcloud}" in
        modules) echo 'registry fwtool https://modules.plaintext.ch/nosec/a/fwtool/index.txt anmeldung-env=MODUL_ABLAGE_FWTOOL' ;;
        *)       echo 'registry guild https://home.plaintext.ch/public.php/webdav/plaintext-guild/index.txt anmeldung-env=X' ;;
    esac
    exit 0
fi
# chef (394): MOCK_MODUS=echt fuehrt das Slot-Skript (stdin) lokal aus - mit Ersatz-wget, der seine Argumente festhaelt.
if [ "${MOCK_MODUS:-}" = "echt" ]; then exec sh; fi
cat > /dev/null
z=$(( $(cat "$ZAEHLER" 2>/dev/null || echo 0) + 1 )); echo "$z" > "$ZAEHLER"
case "$MOCK_MODUS" in
    modules)    printf '#quelle https://modules.plaintext.ch/nosec/a/fwtool/index.txt\nplaintext-modul-index 1\nmodul plaintext-guild-basis 1.629.0 root-min=3.68.0 sha256=ab\nmodul plaintext-guild-x 1.630.0 root-min=3.68.0\n' ;;
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

echo "Karte 2389: Quelle modules.plaintext.ch (modul-Zeile des Basis-Moduls, Abbruch statt Rueckfall):"
export MOCK_MODUS=modules
registry_index_hat_version "1.629.0" "green"; pruefe "modul <basis> <version> im modules-Index -> rc 0" "0" "$?"
registry_index_hat_version "1.630.0" "green"; pruefe "Version nur bei einem anderen Modul -> rc 1" "1" "$?"
registry_index_hat_version "1.62" "green";    pruefe "Versions-Prafix zaehlt auch hier nicht -> rc 1" "1" "$?"
export MOCK_QUELLE=modules
registry_quelle_ist_modules "green"; pruefe "Quelle /nosec/a/ erkannt -> rc 0" "0" "$?"
echo 0 > "$ZAEHLER"
AUSGABE=$(warte_auf_registry_index "1.631.0" "green"); pruefe "modules: Version kommt nie -> rc 1 (Abbruch)" "1" "$?"
pruefe "Meldung «ABBRUCH vor dem Slot-Start»" "ja" "$(grep -q 'ABBRUCH vor dem Slot-Start' <<<"$AUSGABE" && echo ja || echo nein)"
AUSGABE=$(warte_auf_registry_index "1.629.0" "green"); pruefe "modules: Version da -> rc 0" "0" "$?"
export MOCK_QUELLE=nextcloud
registry_quelle_ist_modules "green"; pruefe "Nextcloud-Quelle ist nicht modules -> rc 1" "1" "$?"

echo "chef (394): Zugang nie auf der Kommandozeile (wget liest ihn aus einer Konfigdatei in /dev/shm):"
cat > "$TMPDIR_TEST/wget" <<'EOW'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WGET_ARGV"
for a in "$@"; do case "$a" in --config=*) k="${a#--config=}"; cat "$k" >> "$WGET_KONFIG"; stat -c '%a' "$k" >> "$WGET_RECHTE" ;; esac; done
printf 'plaintext-modul-index 1\nmodul plaintext-guild-basis 1.629.0 root-min=3.68.0\n'
EOW
chmod +x "$TMPDIR_TEST/wget"
export WGET_ARGV="$TMPDIR_TEST/argv" WGET_KONFIG="$TMPDIR_TEST/konfig" WGET_RECHTE="$TMPDIR_TEST/rechte"
printf 'registry fwtool https://modules.example.test/nosec/a/fwtool/index.txt anmeldung-env=TEST_ZUGANG\n' > "$TMPDIR_TEST/quellen.txt"
export MODUL_QUELLEN_DATEI="$TMPDIR_TEST/quellen.txt" TEST_ZUGANG="kunde-x:Geheim-2389-xyz" MOCK_MODUS=echt
registry_index_hat_version "1.629.0" "green"; pruefe "echtes Slot-Skript findet die modul-Zeile -> rc 0" "0" "$?"
pruefe "Passwort NICHT in den wget-Argumenten" "nein" "$(grep -qF 'Geheim-2389-xyz' "$WGET_ARGV" && echo ja || echo nein)"
pruefe "wget bekam --config" "ja" "$(grep -q -- '--config=/dev/shm/' "$WGET_ARGV" && echo ja || echo nein)"
pruefe "Konfigdatei trug Benutzer und Passwort" "ja" "$(grep -q 'user = kunde-x' "$WGET_KONFIG" && grep -q 'password = Geheim-2389-xyz' "$WGET_KONFIG" && echo ja || echo nein)"
pruefe "Konfigdatei nur fuer den Eigentuemer (600)" "600" "$(head -1 "$WGET_RECHTE")"
pruefe "Konfigdatei danach weg" "0" "$(find /dev/shm -maxdepth 1 -name 'registry-warte.*' 2>/dev/null | wc -l)"
unset MODUL_QUELLEN_DATEI TEST_ZUGANG

if [ "$FEHLER" -eq 0 ]; then echo "ALLE TESTS BESTANDEN"; else echo "TESTS FEHLGESCHLAGEN"; exit 1; fi
