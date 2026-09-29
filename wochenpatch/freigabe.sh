#!/bin/sh
# wochenpatch/freigabe.sh — wer darf den Wochenpatch in welchem Modus starten (Karte 1340).
#
# Wird von JEDEM Step in .woodpecker/wochenpatch.yml als erstes GESOURCT (`. wochenpatch/freigabe.sh`);
# das `exit 0` unten beendet dann den Step selbst — mit Erfolg, ohne etwas getan zu haben.
# POSIX-sh, weil Woodpecker die commands mit /bin/sh ausfuehrt (dash im maven-Image).
#
#   cron (Name "wochenpatch")  -> Modus "ausrollen" (Entscheid Daniel, 29.09.2026)
#   manual mit Variable wochenpatch=trocken|pr|ausrollen -> dieser Modus
#   manual OHNE die Variable   -> Ausstieg. Ein Klick auf "Run pipeline" startet JEDE Datei mit
#                                 `event: manual` — auch diese. Er darf nicht nebenbei vier
#                                 Releases ausrollen (Muster: analyse-freigabe.sh in plaintext-app).
case "${CI_PIPELINE_EVENT:-}" in
    cron)
        WOCHENPATCH_MODUS="${WOCHENPATCH_CRON_MODUS:-ausrollen}" ;;
    manual)
        case "${wochenpatch:-}" in
            trocken|pr|ausrollen) WOCHENPATCH_MODUS="$wochenpatch" ;;
            *)
                echo "════════════════════════════════════════════════════════════════"
                echo " AUSSTIEG: manueller Lauf ohne Ansage."
                echo " Der Wochenpatch merged und rollt root, app, guild und schuetu aus."
                echo " Ein Klick auf 'Run pipeline' soll das nicht aus Versehen tun."
                echo ""
                echo " Wirklich gewollt? Im 'Run pipeline'-Dialog die Variable setzen:"
                echo "     wochenpatch = trocken    (Vorflug, keine Wirkung)"
                echo "     wochenpatch = pr         (nur PRs, kein Merge)"
                echo "     wochenpatch = ausrollen  (wie der Sonntags-Cron)"
                echo ""
                echo " Der Step endet mit Erfolg, hat aber nichts getan."
                echo "════════════════════════════════════════════════════════════════"
                exit 0 ;;
        esac ;;
    *)
        echo "wochenpatch: Ereignis '${CI_PIPELINE_EVENT:-}' ist nicht zustaendig, Ausstieg."
        exit 0 ;;
esac
export WOCHENPATCH_MODUS
echo "Wochenpatch freigegeben: Ereignis ${CI_PIPELINE_EVENT}, Modus ${WOCHENPATCH_MODUS}."
