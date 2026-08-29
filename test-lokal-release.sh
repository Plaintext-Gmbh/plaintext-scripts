#!/usr/bin/env bash
# test-lokal-release.sh — bewacht die Sicherungen des Release-Pfads (do_release / do_local_release).
#
# WORUM ES GEHT
#
# Der Lokal-Release ist der zweite Weg neben der CI-Pipeline: Release + Tag + Push + Build +
# Blue-Green-Deploy von einer Entwicklermaschine aus. Er ist nur deshalb ungefaehrlich, weil
# einige Dinge in einer bestimmten REIHENFOLGE bzw. FORM passieren — und genau solche Dinge
# verrutschen beim naechsten Umbau lautlos:
#
#   1. Der Release-Commit traegt das NATIVE "[skip ci]" (mit Leerzeichen) in der BETREFFZEILE —
#      lokal UND in der CI (Zustandsbericht 29.08.2026, Paket S). Sonst startet der Push auf
#      master einen zweiten CI-Lauf (release-all), der parallel einen weiteren Release rechnet.
#      Die Bindestrich-Form "[skip-ci]" kennt GitHub nicht; sie erzeugte Laeufe, die sich nur
#      per Concurrency gegenseitig abbrachen.
#   2. Der Default fuer den Marker liegt in do_release AUSSERHALB des CI-Guards — sonst faellt
#      die CI wieder auf "kein Marker" zurueck.
#   3. Der Vorflug (lokal_vorflug: Branch, Arbeitsbaum, origin, CI, Maven) laeuft VOR do_release —
#      und do_release selbst ruft ihn ausserhalb der CI ebenfalls (./build 3/5/56 lokal).
#   4. Das NAS wird VOR do_release auf Erreichbarkeit geprueft (kein Tag ohne Deploy).
#   5. Das GitHub-Release mit Notes entsteht NACH dem Tag-Push und ist nie fatal (jeder Pfad
#      der Funktion endet mit return 0).
#
# Aufruf:  ./test-lokal-release.sh [pfad-zu-tui-build-logic.sh]
set -uo pipefail

SKRIPT="${1:-$(dirname "$0")/tui-build-logic.sh}"
[ -r "$SKRIPT" ] || { echo "nicht lesbar: $SKRIPT" >&2; exit 2; }

FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
           else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi; }
# Erste Zeile, in der das Muster (LITERAL, kein Regex — index() statt ~, damit Klammern, $ und
# Backslashes nicht escaped werden muessen) im Funktionskoerper der Funktion $1 steht
# (leer = nicht gefunden).
zeile_in() {
    awk -v fn="$1" -v muster="$2" '
        $0 ~ ("^" fn "\\(\\) \\{") { drin=1 }
        drin && index($0, muster) > 0 && !gefunden { print NR; gefunden=1 }
        drin && /^\}/ { drin=0 }
    ' "$SKRIPT" | head -1
}
zeile_in_lokal() { zeile_in do_local_release "$1"; }
koerper() { awk "/^$1\\(\\) \\{/,/^\\}/" "$SKRIPT"; }

echo "Release-Pfad: Sicherungen in $SKRIPT"

# 1. Betreffzeile des Release-Commits traegt den Suffix (erste Zeile von COMMIT_MSG)
BETREFF=$(grep -m1 -E '^\s*COMMIT_MSG="Release version ' "$SKRIPT")
pruefe "Release-Commit-Betreff kennt RELEASE_COMMIT_SUFFIX" \
    "ja" "$(printf '%s' "$BETREFF" | grep -q 'RELEASE_COMMIT_SUFFIX' && echo ja || echo nein)"

# 1b. Der Default ist das NATIVE [skip ci] — und die Bindestrich-Form kommt im Code nicht mehr vor
pruefe "do_release: Default ' [skip ci]' (nativ, mit Leerzeichen)" "ja" \
    "$(koerper do_release | grep -q 'RELEASE_COMMIT_SUFFIX= \[skip ci\]' && echo ja || echo nein)"
pruefe "SNAPSHOT-Commit traegt natives [skip ci]" "ja" \
    "$(koerper do_release | grep -q 'Prepare next development iteration .*\[skip ci\]"' && echo ja || echo nein)"
# Kommentare duerfen die alte Form erklaeren; die Commit-Erzeugung nicht. (lokal_release_ci_frei
# kennt beide Formen absichtlich — deshalb nur die beiden Release-Funktionen.)
BINDESTRICH=$({ koerper do_release; koerper do_local_release; } | grep -v '^\s*#' | grep -c 'skip-ci' || true)
pruefe "kein [skip-ci] (Bindestrich) mehr in do_release/do_local_release" "0" "$BINDESTRICH"

# 2. Der Default liegt NICHT im CI-Guard von do_release (sonst haette die CI keinen Marker)
Z_R_CI_IF=$(zeile_in do_release 'if [ "${CI:-}" != "true" ]')
Z_R_DEFAULT=$(zeile_in do_release 'RELEASE_COMMIT_SUFFIX= [skip ci]')
Z_R_CI_FI=""
if [ -n "${Z_R_CI_IF:-}" ]; then
    Z_R_CI_FI=$(awk -v start="$Z_R_CI_IF" 'NR > start && /^    fi$/ { print NR; exit }' "$SKRIPT")
fi
pruefe "do_release: CI-Guard vorhanden" "ja" "$([ -n "${Z_R_CI_IF:-}" ] && [ -n "${Z_R_CI_FI:-}" ] && echo ja || echo nein)"
if [ -n "${Z_R_CI_IF:-}" ] && [ -n "${Z_R_CI_FI:-}" ] && [ -n "${Z_R_DEFAULT:-}" ]; then
    pruefe "do_release: [skip ci]-Default gilt auch in der CI (ausserhalb des Guards)" "ja" \
        "$([ "$Z_R_DEFAULT" -gt "$Z_R_CI_FI" ] && echo ja || echo nein)"
fi

# 3.-4. Reihenfolge innerhalb von do_local_release
Z_SAUBER=$(zeile_in_lokal 'lokal_vorflug "$BRANCH"')
Z_NAS=$(zeile_in_lokal 'ensure_nas_reachable')
Z_RELEASE=$(zeile_in_lokal 'do_release "$INCREMENT_TYPE"')
Z_PROD=$(zeile_in_lokal 'deploy_to_prod "true"')

pruefe "Vorflug-Aufruf vorhanden"         "ja" "$([ -n "${Z_SAUBER:-}" ] && echo ja || echo nein)"
pruefe "NAS-Pruefung vorhanden"           "ja" "$([ -n "${Z_NAS:-}" ] && echo ja || echo nein)"
pruefe "do_release wird aufgerufen"       "ja" "$([ -n "${Z_RELEASE:-}" ] && echo ja || echo nein)"
pruefe "PROD-Deploy mit Healthcheck"      "ja" "$([ -n "${Z_PROD:-}" ] && echo ja || echo nein)"

if [ -n "${Z_SAUBER:-}" ] && [ -n "${Z_NAS:-}" ] && [ -n "${Z_RELEASE:-}" ] && [ -n "${Z_PROD:-}" ]; then
    pruefe "Vorflug VOR do_release"              "ja" "$([ "$Z_SAUBER" -lt "$Z_RELEASE" ] && echo ja || echo nein)"
    pruefe "NAS-Pruefung VOR do_release"         "ja" "$([ "$Z_NAS" -lt "$Z_RELEASE" ] && echo ja || echo nein)"
    pruefe "PROD-Deploy NACH do_release"         "ja" "$([ "$Z_PROD" -gt "$Z_RELEASE" ] && echo ja || echo nein)"
fi
# Kein Sonderweg mehr: do_local_release setzt den Marker nicht selbst (Default in do_release).
pruefe "do_local_release setzt keinen eigenen Suffix" "0" \
    "$(koerper do_local_release | grep -v '^\s*#' | grep -c 'RELEASE_COMMIT_SUFFIX=' || true)"

# 5. lokal_vorflug prueft den Arbeitsbaum; do_release ruft ihn ausserhalb der CI VOR dem Versionsschritt
pruefe "lokal_vorflug prueft den Arbeitsbaum" "ja" \
    "$(koerper lokal_vorflug | grep -q 'git status --porcelain' && echo ja || echo nein)"
Z_R_VORFLUG=$(zeile_in do_release 'lokal_vorflug')
Z_R_SET=$(zeile_in do_release 'mvn versions:set')
pruefe "do_release: Vorflug VOR versions:set" "ja" \
    "$([ -n "${Z_R_VORFLUG:-}" ] && [ -n "${Z_R_SET:-}" ] && [ "$Z_R_VORFLUG" -lt "$Z_R_SET" ] && echo ja || echo nein)"
for fn in deploy_to_dev deploy_to_prod; do
    pruefe "$fn: lokal CI-Rollout-Sperre" "ja" \
        "$(koerper "$fn" | grep -q 'lokal_release_ci_frei' && echo ja || echo nein)"
done

# 6. Massnahmen 1-5 (29.08.2026, PROD 502 durch zwei parallele Lokal-Releases)
# M1: deploy_blue_green exportiert die Slots; die Aufrufer stoppen NUR diese; stop_slot schuetzt
pruefe "M1: deploy_blue_green exportiert BG_ALT_SLOT/BG_NEU_SLOT" "ja" \
    "$(koerper deploy_blue_green | grep -q 'BG_ALT_SLOT="\$ACTIVE_SLOT"' && koerper deploy_blue_green | grep -q 'BG_NEU_SLOT="\$INACTIVE_SLOT"' && echo ja || echo nein)"
pruefe "M1: deploy_to_prod uebernimmt BG_ALT_SLOT nach dem Deploy" "ja" \
    "$(koerper deploy_to_prod_gesperrt | grep -q 'ACTIVE_SLOT="\${BG_ALT_SLOT:-' && echo ja || echo nein)"
pruefe "M1: deploy_to_dev uebernimmt BG_ALT_SLOT nach dem Deploy" "ja" \
    "$(koerper deploy_to_dev_gesperrt | grep -q 'OLD_SLOT="\${BG_ALT_SLOT:-' && echo ja || echo nein)"
pruefe "M1: alter PROD-Slot wird mit Versions-Schutz gestoppt" "ja" \
    "$(koerper deploy_to_prod_gesperrt | grep -q 'stop_slot "prod" "\$ACTIVE_SLOT" "\$RELEASE_VERSION"' && echo ja || echo nein)"
pruefe "M1: stop_slot verweigert den aktiven Slot (Marker)" "ja" \
    "$(koerper stop_slot | grep -q 'get_active_slot "\$ENV_NAME"' && koerper stop_slot | grep -q 'VERWEIGERT' && echo ja || echo nein)"
pruefe "M1: stop_slot verweigert Container mit der neuen Version" "ja" \
    "$(koerper stop_slot | grep -q 'nosec/version' && echo ja || echo nein)"
# M2: Deploy-Lock auf dem NAS um den ganzen Rollout, Freigabe auf jedem Pfad
pruefe "M2: deploy_to_prod haelt den NAS-Deploy-Lock" "ja" \
    "$(koerper deploy_to_prod | grep -q 'deploy_lock_acquire "prod"' && koerper deploy_to_prod | grep -q 'deploy_lock_release "prod"' && echo ja || echo nein)"
pruefe "M2: deploy_to_dev haelt den NAS-Deploy-Lock" "ja" \
    "$(koerper deploy_to_dev | grep -q 'deploy_lock_acquire "int"' && koerper deploy_to_dev | grep -q 'deploy_lock_release "int"' && echo ja || echo nein)"
pruefe "M2: Staging-Kopie unter Lock" "ja" \
    "$(koerper stage_jar_to_nas | grep -q 'deploy_lock_acquire "staging"' && echo ja || echo nein)"
pruefe "M2: Lock wird nur vom Besitzer geloest" "ja" \
    "$(koerper deploy_lock_release | grep -q 'DEPLOY_LOCK_TOKEN' && echo ja || echo nein)"
pruefe "M2: nginx-Sicherungskopie je Lauf eindeutig" "ja" \
    "$(grep -q 'upstream.conf.\${DEPLOY_LOCK_TOKEN}.bak' "$SKRIPT" && ! grep -q 'upstream.conf.bak' "$SKRIPT" && echo ja || echo nein)"
# M3: pg_dump schnell + fail-fast, Backup nur bei Migration
pruefe "M3: pg_dump ohne -Z 9, mit --lock-wait-timeout" "ja" \
    "$(koerper backup_prod_db | grep -q 'lock-wait-timeout' && ! koerper backup_prod_db | grep -q -- '-Z 9 ' && echo ja || echo nein)"
pruefe "M3: PROD-Backup nur wenn backup_noetig" "ja" \
    "$(koerper deploy_to_prod_gesperrt | grep -q 'if backup_noetig; then' && echo ja || echo nein)"
pruefe "M3: backup_noetig ist fail-safe (unbekannt = sichern)" "ja" \
    "$(koerper backup_noetig | grep -q 'nicht ermittelbar' && echo ja || echo nein)"
# M4: Tests im Lokal-Release, wenn eine DB da ist
Z_TESTFLAG=$(zeile_in_lokal 'lokal_release_testflag')
pruefe "M4: Test-Flag wird im Lokal-Release ermittelt (vor do_release)" "ja" \
    "$([ -n "${Z_TESTFLAG:-}" ] && [ -n "${Z_RELEASE:-}" ] && [ "$Z_TESTFLAG" -lt "$Z_RELEASE" ] && echo ja || echo nein)"
pruefe "M4: mit DB laufen die Unit-Tests wie in der CI" "ja" \
    "$(koerper lokal_release_testflag | grep -q -- '-DskipITs -DexcludedGroups=quality-gate' && echo ja || echo nein)"
# M5: CI-Sperre ignoriert Laeufe mit Skip-Marker (beide Formen, Paket S); Tag-Vorpruefung
pruefe "M5: CI-Sperre ignoriert [skip-ci]- UND [skip ci]-Laeufe" "ja" \
    "$(koerper lokal_release_ci_frei | grep -q 'index(\$5, "\[skip-ci\]") == 0 && index(\$5, "\[skip ci\]") == 0' && echo ja || echo nein)"
Z_TAG=$(zeile_in_lokal 'git ls-remote --tags origin')
pruefe "M5: geplanter Tag wird VOR do_release auf origin geprueft" "ja" \
    "$([ -n "${Z_TAG:-}" ] && [ -n "${Z_RELEASE:-}" ] && [ "$Z_TAG" -lt "$Z_RELEASE" ] && echo ja || echo nein)"

# 7. Rueckbau nimmt nur zurueck, was NICHT auf origin ist
pruefe "Rueckbau prueft origin-Zugehoerigkeit" "ja" \
    "$(koerper lokal_release_rueckbau | grep -q 'merge-base --is-ancestor HEAD' && echo ja || echo nein)"

# 8. GitHub-Release mit Notes: NACH dem Tag-Push, und nie fatal
Z_TAGPUSH=$(zeile_in do_release 'git push origin "refs/tags/')
Z_NOTES=$(zeile_in do_release 'release_notes_erzeugen "${NEW_VERSION}"')
pruefe "Release-Notes werden erzeugt" "ja" "$([ -n "${Z_NOTES:-}" ] && echo ja || echo nein)"
if [ -n "${Z_TAGPUSH:-}" ] && [ -n "${Z_NOTES:-}" ]; then
    pruefe "Release-Notes NACH dem Tag-Push" "ja" "$([ "$Z_NOTES" -gt "$Z_TAGPUSH" ] && echo ja || echo nein)"
fi
pruefe "release_notes_erzeugen: kein fataler Ausstieg (return 1 / exit)" "0" \
    "$(koerper release_notes_erzeugen | grep -v '^\s*#' | grep -cE 'return [1-9]|exit ' || true)"
pruefe "release_notes_erzeugen: prueft auf gh" "ja" \
    "$(koerper release_notes_erzeugen | grep -q 'command -v gh' && echo ja || echo nein)"

if [ "$FEHLER" -eq 0 ]; then echo "alles ok"; else echo "FEHLER"; fi
exit "$FEHLER"
