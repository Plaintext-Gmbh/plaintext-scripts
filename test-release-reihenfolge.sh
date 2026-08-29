#!/usr/bin/env bash
# test-release-reihenfolge.sh — bewacht die Reihenfolge im Release-Lauf (Karte 518).
#
# WORUM ES GEHT
#
# Die naechste Versionsnummer wird aus der POM-Version von master abgeleitet. Wird eine Version
# ins Release-Repo veroeffentlicht, ohne dass master davon erfaehrt, rechnet der naechste Lauf
# DIESELBE Nummer und stirbt an der Kollisionspruefung ("Version X ist im Release-Repo bereits
# veroeffentlicht"). Am 03.08.2026 sind daran sieben master-Laeufe gescheitert; vier gemergte
# Karten lagen ungenutzt auf master.
#
# Der Fix ist eine REIHENFOLGE, kein Codepfad — und Reihenfolgen verrutschen beim naechsten
# Umbau lautlos. Genau deshalb dieser Test: Er liest die Positionen im Skript und stellt sicher,
# dass der Release-Push VOR der Veroeffentlichung steht.
#
# Aufruf:  ./test-release-reihenfolge.sh [pfad-zu-tui-build-logic.sh]
set -uo pipefail

SKRIPT="${1:-$(dirname "$0")/tui-build-logic.sh}"
[ -r "$SKRIPT" ] || { echo "nicht lesbar: $SKRIPT" >&2; exit 2; }

FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
           else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi; }

# Zeilennummer des ersten Treffers (0 = nicht gefunden)
zeile() { grep -n -- "$1" "$SKRIPT" | head -1 | cut -d: -f1 || echo 0; }

TAG=$(zeile 'git tag -a "${NEW_VERSION}"')
PUSH_RELEASE=$(zeile 'Pushing release commit + tag BEFORE publishing')
DEPLOY=$(zeile 'mvn clean deploy')
PUSH_SNAPSHOT=$(zeile 'Pushing next SNAPSHOT commit')

echo "== Fundstellen ============================================================"
printf '  Tag setzen            Zeile %s\n  Push Release+Tag      Zeile %s\n  mvn clean deploy      Zeile %s\n  Push SNAPSHOT         Zeile %s\n' \
       "${TAG:-0}" "${PUSH_RELEASE:-0}" "${DEPLOY:-0}" "${PUSH_SNAPSHOT:-0}"

echo "== Reihenfolge ============================================================"
pruefe "alle vier Stellen vorhanden" "ja" \
       "$([ -n "$TAG" ] && [ -n "$PUSH_RELEASE" ] && [ -n "$DEPLOY" ] && [ -n "$PUSH_SNAPSHOT" ] && echo ja || echo nein)"

# DER KERN: veroeffentlicht wird erst, wenn master den Release kennt.
pruefe "Release-Push steht VOR mvn deploy" "ja" \
       "$([ "${PUSH_RELEASE:-0}" -lt "${DEPLOY:-0}" ] 2>/dev/null && echo ja || echo nein)"
pruefe "Release-Push steht NACH dem Tag" "ja" \
       "$([ "${PUSH_RELEASE:-0}" -gt "${TAG:-0}" ] 2>/dev/null && echo ja || echo nein)"
pruefe "SNAPSHOT-Push steht NACH mvn deploy" "ja" \
       "$([ "${PUSH_SNAPSHOT:-0}" -gt "${DEPLOY:-0}" ] 2>/dev/null && echo ja || echo nein)"

# Massnahme 4 (29.08.2026): die Selbstkontrolle "liegt jedes Modul im Release-Repo?" gehoert
# unmittelbar HINTER mvn deploy und VOR den SNAPSHOT-Push — sie prueft das Ergebnis des Deploys,
# nicht den Zustand davor, und darf den Release nicht verzoegern (nie fatal, test-root-autobump.sh).
SELBST=$(zeile 'release_vollstaendig_pruefen "${NEW_VERSION}"')
pruefe "Selbstkontrolle (release_vollstaendig_pruefen) vorhanden" "ja" \
       "$([ -n "$SELBST" ] && echo ja || echo nein)"
pruefe "Selbstkontrolle steht NACH mvn deploy" "ja" \
       "$([ "${SELBST:-0}" -gt "${DEPLOY:-0}" ] 2>/dev/null && echo ja || echo nein)"
pruefe "Selbstkontrolle steht VOR dem SNAPSHOT-Push" "ja" \
       "$([ "${SELBST:-0}" -lt "${PUSH_SNAPSHOT:-0}" ] 2>/dev/null && echo ja || echo nein)"

echo "== Fehlerverhalten ========================================================"
# Scheitert der Release-Push, ist nichts veroeffentlicht -> harter Abbruch ist richtig.
NACH_PUSH=$(sed -n "${PUSH_RELEASE},$((PUSH_RELEASE + 14))p" "$SKRIPT" 2>/dev/null)
pruefe "gescheiterter Release-Push bricht ab" "ja" \
       "$(printf '%s' "$NACH_PUSH" | grep -q 'return 1' && echo ja || echo nein)"
pruefe "und sagt, dass nichts veroeffentlicht wurde" "ja" \
       "$(printf '%s' "$NACH_PUSH" | grep -qi 'NICHTS veroeffentlicht' && echo ja || echo nein)"

# Scheitert der SNAPSHOT-Push, ist der Release vollstaendig -> nur Warnung, kein rotes Ergebnis.
NACH_SNAP=$(sed -n "${PUSH_SNAPSHOT},$((PUSH_SNAPSHOT + 10))p" "$SKRIPT" 2>/dev/null)
pruefe "gescheiterter SNAPSHOT-Push bricht NICHT ab" "ja" \
       "$(printf '%s' "$NACH_SNAP" | grep -q 'return 1' && echo nein || echo ja)"

echo "== Syntax ================================================================="
pruefe "Skript ist syntaktisch gueltig" "ja" "$(bash -n "$SKRIPT" 2>/dev/null && echo ja || echo nein)"

echo
if [ "$FEHLER" = "0" ]; then echo "ERGEBNIS: alle Faelle wie erwartet"; else echo "ERGEBNIS: FEHLER"; fi
exit "$FEHLER"
