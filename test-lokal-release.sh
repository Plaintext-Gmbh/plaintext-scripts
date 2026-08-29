#!/usr/bin/env bash
# test-lokal-release.sh — bewacht die Sicherungen des Lokal-Release (do_local_release).
#
# WORUM ES GEHT
#
# Der Lokal-Release ist der zweite Weg neben der CI-Pipeline: Release + Tag + Push + Build +
# Blue-Green-Deploy von einer Entwicklermaschine aus. Er ist nur deshalb ungefaehrlich, weil
# vier Dinge in einer bestimmten REIHENFOLGE bzw. FORM passieren — und genau solche Dinge
# verrutschen beim naechsten Umbau lautlos:
#
#   1. Der Release-Commit traegt "[skip-ci]" in der BETREFFZEILE. Sonst startet der Push auf
#      master die CI (release-all), die parallel einen zweiten Release deployt.
#   2. Der Vorflug (lokal_vorflug: Branch, Arbeitsbaum, origin, CI, Maven) laeuft VOR do_release —
#      und do_release selbst ruft ihn ausserhalb der CI ebenfalls (./build 3/5/56 lokal).
#   3. Das NAS wird VOR do_release auf Erreichbarkeit geprueft (kein Tag ohne Deploy).
#   4. Der Suffix wird VOR do_release gesetzt und nach dem Aufruf wieder geleert.
#
# Aufruf:  ./test-lokal-release.sh [pfad-zu-tui-build-logic.sh]
set -uo pipefail

SKRIPT="${1:-$(dirname "$0")/tui-build-logic.sh}"
[ -r "$SKRIPT" ] || { echo "nicht lesbar: $SKRIPT" >&2; exit 2; }

FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
           else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi; }
# Erste Zeile, in der das Muster im Funktionskoerper von do_local_release steht (0 = nicht gefunden).
zeile_in_lokal() {
    awk -v muster="$1" '
        /^do_local_release\(\) \{/ { drin=1 }
        drin && $0 ~ muster && !gefunden { print NR; gefunden=1 }
        drin && /^\}/ { drin=0 }
    ' "$SKRIPT" | head -1
}

echo "Lokal-Release: Sicherungen in $SKRIPT"

# 1. Betreffzeile des Release-Commits traegt den Suffix (erste Zeile von COMMIT_MSG)
BETREFF=$(grep -m1 -E '^\s*COMMIT_MSG="Release version ' "$SKRIPT")
pruefe "Release-Commit-Betreff kennt RELEASE_COMMIT_SUFFIX" \
    "ja" "$(printf '%s' "$BETREFF" | grep -q 'RELEASE_COMMIT_SUFFIX' && echo ja || echo nein)"

# 2.-4. Reihenfolge innerhalb von do_local_release
Z_SAUBER=$(zeile_in_lokal 'lokal_vorflug "\\$BRANCH"')
Z_NAS=$(zeile_in_lokal 'ensure_nas_reachable')
Z_SUFFIX=$(zeile_in_lokal 'RELEASE_COMMIT_SUFFIX=" \\[skip-ci\\]"')
Z_RELEASE=$(zeile_in_lokal 'do_release "\\$INCREMENT_TYPE"')
Z_PROD=$(zeile_in_lokal 'deploy_to_prod "true"')

pruefe "Vorflug-Aufruf vorhanden"         "ja" "$([ -n "${Z_SAUBER:-}" ] && echo ja || echo nein)"
pruefe "NAS-Pruefung vorhanden"           "ja" "$([ -n "${Z_NAS:-}" ] && echo ja || echo nein)"
pruefe "[skip-ci]-Suffix wird gesetzt"    "ja" "$([ -n "${Z_SUFFIX:-}" ] && echo ja || echo nein)"
pruefe "do_release wird aufgerufen"       "ja" "$([ -n "${Z_RELEASE:-}" ] && echo ja || echo nein)"
pruefe "PROD-Deploy mit Healthcheck"      "ja" "$([ -n "${Z_PROD:-}" ] && echo ja || echo nein)"

if [ -n "${Z_SAUBER:-}" ] && [ -n "${Z_NAS:-}" ] && [ -n "${Z_SUFFIX:-}" ] && [ -n "${Z_RELEASE:-}" ] && [ -n "${Z_PROD:-}" ]; then
    pruefe "Vorflug VOR do_release"              "ja" "$([ "$Z_SAUBER" -lt "$Z_RELEASE" ] && echo ja || echo nein)"
    pruefe "NAS-Pruefung VOR do_release"         "ja" "$([ "$Z_NAS" -lt "$Z_RELEASE" ] && echo ja || echo nein)"
    pruefe "[skip-ci]-Suffix VOR do_release"     "ja" "$([ "$Z_SUFFIX" -lt "$Z_RELEASE" ] && echo ja || echo nein)"
    pruefe "PROD-Deploy NACH do_release"         "ja" "$([ "$Z_PROD" -gt "$Z_RELEASE" ] && echo ja || echo nein)"
    # Der Suffix darf nicht in der Umgebung haengen bleiben (spaeteres ./build 3 waere sonst [skip-ci]).
    Z_LEER=$(awk -v start="$Z_RELEASE" 'NR > start && /RELEASE_COMMIT_SUFFIX=""/ { print NR; exit }' "$SKRIPT")
    pruefe "Suffix nach do_release geleert"      "ja" "$([ -n "${Z_LEER:-}" ] && echo ja || echo nein)"
fi

# 5. lokal_vorflug prueft den Arbeitsbaum; do_release ruft ihn ausserhalb der CI VOR dem Versionsschritt
pruefe "lokal_vorflug prueft den Arbeitsbaum" "ja" \
    "$(awk '/^lokal_vorflug\(\) \{/,/^\}/' "$SKRIPT" | grep -q 'git status --porcelain' && echo ja || echo nein)"
Z_R_VORFLUG=$(awk '/^do_release\(\) \{/{d=1} d && /lokal_vorflug/ && !g {print NR; g=1} d && /^\}/{d=0}' "$SKRIPT" | head -1)
Z_R_SET=$(awk '/^do_release\(\) \{/{d=1} d && /mvn versions:set/ && !g {print NR; g=1} d && /^\}/{d=0}' "$SKRIPT" | head -1)
pruefe "do_release: Vorflug VOR versions:set" "ja" \
    "$([ -n "${Z_R_VORFLUG:-}" ] && [ -n "${Z_R_SET:-}" ] && [ "$Z_R_VORFLUG" -lt "$Z_R_SET" ] && echo ja || echo nein)"
pruefe "do_release: lokal [skip-ci]-Default" "ja" \
    "$(awk '/^do_release\(\) \{/,/^\}/' "$SKRIPT" | grep -q 'RELEASE_COMMIT_SUFFIX= \[skip-ci\]' && echo ja || echo nein)"
for fn in deploy_to_dev deploy_to_prod; do
    pruefe "$fn: lokal CI-Rollout-Sperre" "ja" \
        "$(awk "/^${fn}\\(\\) \\{/,/^\\}/" "$SKRIPT" | grep -q 'lokal_release_ci_frei' && echo ja || echo nein)"
done

# 6. Rueckbau nimmt nur zurueck, was NICHT auf origin ist
pruefe "Rueckbau prueft origin-Zugehoerigkeit" "ja" \
    "$(awk '/^lokal_release_rueckbau\(\) \{/,/^\}/' "$SKRIPT" | grep -q 'merge-base --is-ancestor HEAD' && echo ja || echo nein)"

if [ "$FEHLER" -eq 0 ]; then echo "alles ok"; else echo "FEHLER"; fi
exit "$FEHLER"
