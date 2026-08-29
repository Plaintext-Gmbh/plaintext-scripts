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

# 7. Massnahmen 1-5 (29.08.2026, PROD 502 durch zwei parallele Lokal-Releases)
fn_body() { awk "/^${1}\\(\\) \\{/,/^\\}/" "$SKRIPT"; }
# M1: deploy_blue_green exportiert die Slots; die Aufrufer stoppen NUR diese; stop_slot schuetzt
pruefe "M1: deploy_blue_green exportiert BG_ALT_SLOT/BG_NEU_SLOT" "ja" \
    "$(fn_body deploy_blue_green | grep -q 'BG_ALT_SLOT="\$ACTIVE_SLOT"' && fn_body deploy_blue_green | grep -q 'BG_NEU_SLOT="\$INACTIVE_SLOT"' && echo ja || echo nein)"
pruefe "M1: deploy_to_prod uebernimmt BG_ALT_SLOT nach dem Deploy" "ja" \
    "$(fn_body deploy_to_prod_gesperrt | grep -q 'ACTIVE_SLOT="\${BG_ALT_SLOT:-' && echo ja || echo nein)"
pruefe "M1: deploy_to_dev uebernimmt BG_ALT_SLOT nach dem Deploy" "ja" \
    "$(fn_body deploy_to_dev_gesperrt | grep -q 'OLD_SLOT="\${BG_ALT_SLOT:-' && echo ja || echo nein)"
pruefe "M1: alter PROD-Slot wird mit Versions-Schutz gestoppt" "ja" \
    "$(fn_body deploy_to_prod_gesperrt | grep -q 'stop_slot "prod" "\$ACTIVE_SLOT" "\$RELEASE_VERSION"' && echo ja || echo nein)"
pruefe "M1: stop_slot verweigert den aktiven Slot (Marker)" "ja" \
    "$(fn_body stop_slot | grep -q 'get_active_slot "\$ENV_NAME"' && fn_body stop_slot | grep -q 'VERWEIGERT' && echo ja || echo nein)"
pruefe "M1: stop_slot verweigert Container mit der neuen Version" "ja" \
    "$(fn_body stop_slot | grep -q 'nosec/version' && echo ja || echo nein)"
# M2: Deploy-Lock auf dem NAS um den ganzen Rollout, Freigabe auf jedem Pfad
pruefe "M2: deploy_to_prod haelt den NAS-Deploy-Lock" "ja" \
    "$(fn_body deploy_to_prod | grep -q 'deploy_lock_acquire "prod"' && fn_body deploy_to_prod | grep -q 'deploy_lock_release "prod"' && echo ja || echo nein)"
pruefe "M2: deploy_to_dev haelt den NAS-Deploy-Lock" "ja" \
    "$(fn_body deploy_to_dev | grep -q 'deploy_lock_acquire "int"' && fn_body deploy_to_dev | grep -q 'deploy_lock_release "int"' && echo ja || echo nein)"
pruefe "M2: Staging-Kopie unter Lock" "ja" \
    "$(fn_body stage_jar_to_nas | grep -q 'deploy_lock_acquire "staging"' && echo ja || echo nein)"
pruefe "M2: Lock wird nur vom Besitzer geloest" "ja" \
    "$(fn_body deploy_lock_release | grep -q 'DEPLOY_LOCK_TOKEN' && echo ja || echo nein)"
pruefe "M2: nginx-Sicherungskopie je Lauf eindeutig" "ja" \
    "$(grep -q 'upstream.conf.\${DEPLOY_LOCK_TOKEN}.bak' "$SKRIPT" && ! grep -q 'upstream.conf.bak' "$SKRIPT" && echo ja || echo nein)"
# M3: pg_dump schnell + fail-fast, Backup nur bei Migration
pruefe "M3: pg_dump ohne -Z 9, mit --lock-wait-timeout" "ja" \
    "$(fn_body backup_prod_db | grep -q 'lock-wait-timeout' && ! fn_body backup_prod_db | grep -q -- '-Z 9 ' && echo ja || echo nein)"
pruefe "M3: PROD-Backup nur wenn backup_noetig" "ja" \
    "$(fn_body deploy_to_prod_gesperrt | grep -q 'if backup_noetig; then' && echo ja || echo nein)"
pruefe "M3: backup_noetig ist fail-safe (unbekannt = sichern)" "ja" \
    "$(fn_body backup_noetig | grep -q 'nicht ermittelbar' && echo ja || echo nein)"
# M4: Tests im Lokal-Release, wenn eine DB da ist
Z_TESTFLAG=$(zeile_in_lokal 'lokal_release_testflag')
pruefe "M4: Test-Flag wird im Lokal-Release ermittelt (vor do_release)" "ja" \
    "$([ -n "${Z_TESTFLAG:-}" ] && [ -n "${Z_RELEASE:-}" ] && [ "$Z_TESTFLAG" -lt "$Z_RELEASE" ] && echo ja || echo nein)"
pruefe "M4: mit DB laufen die Unit-Tests wie in der CI" "ja" \
    "$(fn_body lokal_release_testflag | grep -q -- '-DskipITs -DexcludedGroups=quality-gate' && echo ja || echo nein)"
# M5: CI-Sperre ignoriert [skip-ci]-Laeufe; Tag-Vorpruefung
pruefe "M5: CI-Sperre ignoriert [skip-ci]-Laeufe" "ja" \
    "$(fn_body lokal_release_ci_frei | grep -q 'index(\$5, "\[skip-ci\]") == 0' && echo ja || echo nein)"
Z_TAG=$(zeile_in_lokal 'git ls-remote --tags origin')
pruefe "M5: geplanter Tag wird VOR do_release auf origin geprueft" "ja" \
    "$([ -n "${Z_TAG:-}" ] && [ -n "${Z_RELEASE:-}" ] && [ "$Z_TAG" -lt "$Z_RELEASE" ] && echo ja || echo nein)"

# 6. Rueckbau nimmt nur zurueck, was NICHT auf origin ist
pruefe "Rueckbau prueft origin-Zugehoerigkeit" "ja" \
    "$(awk '/^lokal_release_rueckbau\(\) \{/,/^\}/' "$SKRIPT" | grep -q 'merge-base --is-ancestor HEAD' && echo ja || echo nein)"

if [ "$FEHLER" -eq 0 ]; then echo "alles ok"; else echo "FEHLER"; fi
exit "$FEHLER"
