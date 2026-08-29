#!/usr/bin/env bash
# test-versionsschritt.sh — bewacht die Versionsrechnung des Release-Laufs.
#
# WORUM ES GEHT
#
# Die naechste Release-Nummer wird aus der POM-Version GERECHNET (POM-Version + ein Schritt).
# Bis zum 28.08.2026 setzte der Release-Lauf die POM danach auf die UEBERNAECHSTE Nummer
# ("MINOR + 1" wurde ein zweites Mal auf die schon erhoehte MINOR angewandt). Der folgende Lauf
# rechnete von dort aus erneut hoch — jede zweite Nummer blieb unbenutzt:
#
#   plaintext-root   1.605.0 -> 1.607.0 -> 1.609.0 -> 1.611.0
#   plaintext-app    2.376.0 -> 2.378.0 -> 2.380.0 -> 2.382.0
#   plaintext-iot    1.330.0 -> 1.332.0 -> 1.334.0 -> 1.336.0
#
# Der Fix ist eine EINZELNE Rechnung (compute_release_versions), und genau solche Rechnungen
# verrutschen beim naechsten Umbau lautlos. Dieser Test schneidet die Funktion aus dem Skript,
# ruft sie direkt auf und faehrt ganze Release-KETTEN durch — eine Luecke faellt damit sofort auf.
#
# Aufruf:  ./test-versionsschritt.sh [pfad-zu-tui-build-logic.sh]
set -uo pipefail

SKRIPT="${1:-$(dirname "$0")/tui-build-logic.sh}"
[ -r "$SKRIPT" ] || { echo "nicht lesbar: $SKRIPT" >&2; exit 2; }

FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
           else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi; }

# Die Funktion aus dem Skript schneiden und einzeln laden. Das ganze tui-build-logic.sh zu sourcen
# geht nicht: es verlangt build-conf.txt und beendet sich sonst mit exit 1.
AUSSCHNITT="$(mktemp)"
trap 'rm -f "$AUSSCHNITT"' EXIT
awk '/^compute_release_versions\(\) \{$/,/^\}$/' "$SKRIPT" > "$AUSSCHNITT"
awk '/^hoechste_version\(\) \{$/,/^\}$/' "$SKRIPT" >> "$AUSSCHNITT"

if ! grep -q 'compute_release_versions()' "$AUSSCHNITT"; then
    echo "  FEHL compute_release_versions() nicht im Skript gefunden" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$AUSSCHNITT"

echo "== Einzelschritte ========================================================="
pruefe "MINOR aus SNAPSHOT"        "1.617.0 1.617.0-SNAPSHOT"   "$(compute_release_versions '1.616.0-SNAPSHOT' 2)"
pruefe "MINOR ist der Standard"    "1.617.0 1.617.0-SNAPSHOT"   "$(compute_release_versions '1.616.0-SNAPSHOT')"
pruefe "MAJOR setzt MINOR/PATCH 0" "2.0.0 2.0.0-SNAPSHOT"       "$(compute_release_versions '1.616.4-SNAPSHOT' 1)"
pruefe "PATCH laesst MINOR stehen" "1.616.5 1.616.5-SNAPSHOT"   "$(compute_release_versions '1.616.4-SNAPSHOT' 3)"
pruefe "MINOR setzt PATCH auf 0"   "1.617.0 1.617.0-SNAPSHOT"   "$(compute_release_versions '1.616.4-SNAPSHOT' 2)"

echo "== Robustheit ============================================================="
# Scheitert der SNAPSHOT-Push, traegt master die nackte Release-Version (siehe do_release,
# "Push des SNAPSHOT-Commits abgelehnt"). Der naechste Lauf muss von dort sauber weiterzaehlen.
pruefe "POM ohne -SNAPSHOT"        "1.618.0 1.618.0-SNAPSHOT"   "$(compute_release_versions '1.617.0' 2)"
pruefe "zweistellige Version"      "1.618.0 1.618.0-SNAPSHOT"   "$(compute_release_versions '1.617-SNAPSHOT' 2)"
pruefe "Notfall-Default 1.0.0"     "1.1.0 1.1.0-SNAPSHOT"       "$(compute_release_versions '1.0.0-SNAPSHOT' 2)"

echo "== Release-Ketten (der eigentliche Punkt) ================================="
# Fuenf Releases hintereinander, so wie der Lauf es macht: rechnen, veroeffentlichen,
# POM auf die naechste SNAPSHOT-Version setzen, von dort weiter.
kette() {
    local POM="$1" TYP="$2" RUNDEN="$3" REL SNAP AUSGABE=""
    for _ in $(seq "$RUNDEN"); do
        read -r REL SNAP <<< "$(compute_release_versions "$POM" "$TYP")"
        AUSGABE="${AUSGABE}${AUSGABE:+ }${REL}"
        POM="$SNAP"          # genau das macht `mvn versions:set` am Ende von do_release
    done
    echo "$AUSGABE"
}

pruefe "root: 5 MINOR-Releases lueckenlos" \
       "1.617.0 1.618.0 1.619.0 1.620.0 1.621.0" "$(kette '1.616.0-SNAPSHOT' 2 5)"
pruefe "app: 5 MINOR-Releases lueckenlos" \
       "2.383.0 2.384.0 2.385.0 2.386.0 2.387.0" "$(kette '2.382.0-SNAPSHOT' 2 5)"
pruefe "3 PATCH-Releases lueckenlos" \
       "1.616.1 1.616.2 1.616.3" "$(kette '1.616.0-SNAPSHOT' 3 3)"
pruefe "3 MAJOR-Releases lueckenlos" \
       "2.0.0 3.0.0 4.0.0" "$(kette '1.616.0-SNAPSHOT' 1 3)"

# Gemischt: MAJOR, dann MINOR, dann PATCH — jeder Schritt setzt auf dem vorigen auf.
read -r R1 S1 <<< "$(compute_release_versions '1.616.0-SNAPSHOT' 1)"
read -r R2 S2 <<< "$(compute_release_versions "$S1" 2)"
read -r R3 _  <<< "$(compute_release_versions "$S2" 3)"
pruefe "MAJOR -> MINOR -> PATCH" "2.0.0 2.1.0 2.1.1" "$R1 $R2 $R3"

echo "== Massnahme 11: Basis = MAX(Tag, POM) ===================================="
pruefe "Tag liegt vor der POM -> Tag"       "2.1710.0" "$(hoechste_version '2.1708.0-SNAPSHOT' '2.1710.0')"
pruefe "POM liegt vor dem Tag -> POM"       "2.1711.0" "$(hoechste_version '2.1711.0-SNAPSHOT' '2.1710.0')"
pruefe "gleich -> gleich"                    "2.1710.0" "$(hoechste_version '2.1710.0-SNAPSHOT' '2.1710.0')"
pruefe "kein Tag -> POM"                     "1.0.0"    "$(hoechste_version '1.0.0-SNAPSHOT' '')"
pruefe "numerisch, nicht lexikalisch"       "1.100.0"  "$(hoechste_version '1.99.0' '1.100.0')"
pruefe "Folge-Release nach abgebrochenem Lauf (Tag 2.1710.0, POM 2.1709.0-SNAPSHOT) = 2.1711.0" \
       "2.1711.0 2.1711.0-SNAPSHOT" "$(compute_release_versions "$(hoechste_version '2.1709.0-SNAPSHOT' '2.1710.0')" 2)"
pruefe "do_release rechnet ab versionsbasis" "ja" \
       "$(sed -n '/^do_release() {/,/^}/p' "$SKRIPT" | grep -q 'compute_release_versions "$(versionsbasis' && echo ja || echo nein)"
pruefe "Lokal-Release-Plan rechnet ab versionsbasis" "ja" \
       "$(sed -n '/^do_local_release() {/,/^}/p' "$SKRIPT" | grep -q 'compute_release_versions "$(versionsbasis' && echo ja || echo nein)"

echo "== Regressionswaechter ===================================================="
# Der alte Fehler in Reinform: die zweite Erhoehung auf der bereits erhoehten MINOR.
pruefe "keine zweite MINOR-Erhoehung (NEXT_MINOR) mehr im Skript" "ja" \
       "$(grep -q 'NEXT_MINOR' "$SKRIPT" && echo nein || echo ja)"
pruefe "SNAPSHOT traegt die Release-Nummer" "ja" \
       "$(grep -q 'echo "${NEU} ${NEU}-SNAPSHOT"' "$SKRIPT" && echo ja || echo nein)"
# Die Funktion darf nicht korrekt und gleichzeitig ungenutzt sein.
pruefe "do_release benutzt compute_release_versions" "ja" \
       "$(sed -n '/^do_release() {/,/^}/p' "$SKRIPT" | grep -q 'compute_release_versions' && echo ja || echo nein)"
pruefe "do_release rechnet nicht selbst" "ja" \
       "$(sed -n '/^do_release() {/,/^}/p' "$SKRIPT" | grep -qE '(MINOR|MAJOR|PATCH)=\$\(\(' && echo nein || echo ja)"

echo "== Syntax ================================================================="
pruefe "Skript ist syntaktisch gueltig" "ja" "$(bash -n "$SKRIPT" 2>/dev/null && echo ja || echo nein)"

echo
if [ "$FEHLER" = "0" ]; then echo "ERGEBNIS: alle Faelle wie erwartet"; else echo "ERGEBNIS: FEHLER"; fi
exit "$FEHLER"
