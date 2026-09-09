#!/usr/bin/env bash
# test-skript-klon-zweig.sh — bewacht die Sicherung aus Karte 1154:
#
#   Die Build-Logik, die einen lokalen Release oder einen PROD-Deploy fährt, muss selbst von
#   'master' kommen.
#
# WORUM ES GEHT (Vorfall Karte 1151, 09.09.2026): ~/codeplain/plaintext-scripts stand elf Tage
# auf einem Zweig, den GitHub längst gelöscht hatte. Ein Handstart hätte in dieser Zeit PROD ohne
# NAS-Deploy-Lock und ohne Migrations-Backup ausgerollt (gemessen: 0 statt 22 Vorkommen von
# `deploy_lock` in tui-build-logic.sh). `lokal_vorflug` prüfte den Zweig der APP — nur seinen
# eigenen nicht.
#
# GEPRÜFT WIRD IN BEIDE RICHTUNGEN, sonst belegt der Test nichts:
#   Negativprobe    Seitenzweig  -> Rückgabe 1, Meldung nennt Zweig, Soll und die Türe
#   Positivkontrolle master      -> Rückgabe 0, keine Abbruchmeldung
#   Türe            PLAINTEXT_SCRIPTS_ZWEIG_EGAL=1 auf dem Seitenzweig -> Rückgabe 0 mit Warnung
#   Sonderfälle     kein git-Klon -> Warnung statt Abbruch; hinter origin/master -> Warnung
#   Verdrahtung     lokal_vorflug und deploy_to_prod rufen die Prüfung VOR allem Wirksamen auf,
#                   der reine Bau (do_build_snapshot) und do_run rufen sie NICHT auf.
#
# KEIN `| grep -q` in diesem Skript: mit `set -o pipefail` macht der SIGPIPE-Abbruch von grep aus
# einer erfolgreichen Suche eine gescheiterte Pipeline — das ist die Ursache des sporadischen Rot
# in den älteren Testskripten (Karte 1155). Hier wird ausschliesslich mit `[[ $x == *muster* ]]`
# verglichen.
#
# Aufruf:  ./test-skript-klon-zweig.sh [pfad-zu-tui-build-logic.sh]
set -uo pipefail

SKRIPT="${1:-$(dirname "$0")/tui-build-logic.sh}"
[ -r "$SKRIPT" ] || { echo "nicht lesbar: $SKRIPT" >&2; exit 2; }
SKRIPT="$(cd "$(dirname "$SKRIPT")" && pwd)/$(basename "$SKRIPT")"

FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
           else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi; }
# ── Karte 1155: kein `... | grep -q` und kein `... | head -1` unter `set -o pipefail` ─────────
# `grep -q` steigt beim ERSTEN Treffer aus und schliesst das Leseende. Der Schreiber der Pipe
# (awk/sed/grep -v) liest die 164-KB-Datei danach noch bis zum Ende und schreibt seinen naechsten
# Puffer-Block (stdio, 4 KB) in eine geschlossene Pipe: SIGPIPE, Rueckgabewert 141. `pipefail`
# reicht das als Pipeline-Fehler durch — die Pruefung meldete "nein", obwohl das Muster dasteht.
# Bedingung ist also nicht die Groesse allein, sondern ein WEITERER Schreibvorgang nach dem
# Treffer: Koerper ueber ~4 KB mit dem Treffer im ersten Block trifft es, `printf "$BLOCK"` mit
# einem einzigen write() nicht. Gemessen am 09.09.2026: test-lokal-release.sh 26 von 40 Laeufen
# rot, test-versionsschritt.sh 18 von 40 — ohne dass am geprueften Code etwas gefehlt haette.
#
# Gefaehrlicher als das falsche Rot ist das falsche GRUEN bei den invertierten Pruefungen
# (`... | grep_q MUSTER && echo nein || echo ja`): dort faellt der Fehlschlag auf "in Ordnung".
# Gemessen an einer absichtlich eingebauten Regression in einem 16-KB-Funktionskoerper: 15 von 20
# Laeufen meldeten "ja" — die Sicherung schwieg genau im Regressionsfall.
#
# `grep_q` liest die Eingabe VOLLSTAENDIG (grep -c) und meldet denselben Rueckgabewert wie
# `grep -q`: 0 = mindestens ein Treffer, 1 = keiner. Optionen und Muster gehen unveraendert durch,
# die Aussage jeder Pruefung bleibt damit gleich — nur der Wettlauf ist weg. Aus demselben Grund
# steht statt `| head -1` jetzt `| sed -n 1p`: sed liest bis EOF, head steigt vorher aus.
grep_q() { local n; n=$(grep -c "$@") || true; [ "${n:-0}" -gt 0 ]; }
koerper() { awk "/^$1\\(\\) \\{/,/^\\}/" "$SKRIPT"; }
# Erste Zeile mit dem LITERAL $2 im Körper der Funktion $1 (leer = nicht gefunden).
zeile_in() {
    awk -v fn="$1" -v muster="$2" '
        $0 ~ ("^" fn "\\(\\) \\{") { drin=1 }
        drin && index($0, muster) > 0 && !gefunden { print NR; gefunden=1 }
        drin && /^\}/ { drin=0 }
    ' "$SKRIPT" | sed -n 1p
}

echo "Skript-Klon-Zweig: Sicherung in $SKRIPT"

# ── Teil 1: die Funktion selbst, verhaltensecht in einem Wegwerf-Klon ─────────────────────
# Die Funktion leitet den zu prüfenden Klon aus ${BASH_SOURCE[0]} ab — dem Klon, aus dem sie
# geladen wurde. Deshalb wird sie hier in eine Datei IN einem Wegwerf-Klon geschrieben und von
# dort gesourct: nur so prüft der Test den Mechanismus und nicht eine Nachbildung.
FN=$(koerper skript_klon_zweig_pruefen)
# Positivkontrolle der Extraktion: ohne sie wäre ein leerer Funktionskörper ein grüner Test.
pruefe "Funktion skript_klon_zweig_pruefen gefunden" "ja" \
    "$([ -n "$FN" ] && [[ $FN == *"PLAINTEXT_SCRIPTS_ZWEIG_EGAL"* ]] && echo ja || echo nein)"
if [ -z "$FN" ]; then
    echo "  (ohne Funktion keine Verhaltensproben)"; exit 1
fi

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT
G="git -c user.email=test@example.com -c user.name=Test -c init.defaultBranch=master -c commit.gpgsign=false"

lib_schreiben() {   # $1 = Zielverzeichnis
    { echo '#!/usr/bin/env bash'
      echo "RED=''; GREEN=''; YELLOW=''; NC=''"
      printf '%s\n' "$FN"
    } > "$1/lib.sh"
}

# Wegwerf-"origin" und ein Klon davon: so ist origin/master echt und der Abstand messbar.
mkdir -p "$TESTDIR/origin"
( cd "$TESTDIR/origin" && $G init -q --bare ) || exit 2
mkdir -p "$TESTDIR/klon"
( cd "$TESTDIR/klon" && $G init -q && lib_schreiben . && $G add -A && $G commit -qm erst \
  && $G remote add origin "$TESTDIR/origin" && $G push -q origin master ) || exit 2
lib_schreiben "$TESTDIR/klon"

# probe <umgebung> -> "rc|ausgabe"; jede Probe in einer eigenen Subshell (frischer Merker).
probe() {
    local AUS RC
    AUS=$(cd "$TESTDIR/klon" && env "$@" bash -c 'source ./lib.sh; skript_klon_zweig_pruefen' 2>&1)
    RC=$?
    printf '%s|%s' "$RC" "$AUS"
}

# 1a. Positivkontrolle: master
A=$(probe PLAINTEXT_SCRIPTS_ZWEIG_EGAL=)
pruefe "master: Rueckgabe 0"                "0"  "${A%%|*}"
pruefe "master: meldet die Herkunft"        "ja" "$([[ ${A#*|} == *"Build-Logik von master"* ]] && echo ja || echo nein)"
pruefe "master: keine Abbruchmeldung"       "ja" "$([[ ${A#*|} != *"kommt nicht von 'master'"* ]] && echo ja || echo nein)"

# 1b. Negativprobe: Seitenzweig
( cd "$TESTDIR/klon" && $G checkout -q -b seitenzweig ) || exit 2
B=$(probe PLAINTEXT_SCRIPTS_ZWEIG_EGAL=)
pruefe "Seitenzweig: Rueckgabe 1"           "1"  "${B%%|*}"
pruefe "Seitenzweig: nennt den Zweig"       "ja" "$([[ ${B#*|} == *"'seitenzweig'"* ]] && echo ja || echo nein)"
pruefe "Seitenzweig: nennt das Soll"        "ja" "$([[ ${B#*|} == *"erwartet: 'master'"* ]] && echo ja || echo nein)"
pruefe "Seitenzweig: nennt die Abhilfe"     "ja" "$([[ ${B#*|} == *"checkout master"* ]] && echo ja || echo nein)"
# Eine Tuere, die man nicht findet, ist keine: die Variable MUSS in der Abbruchmeldung stehen.
pruefe "Seitenzweig: nennt die Tuere"       "ja" "$([[ ${B#*|} == *"PLAINTEXT_SCRIPTS_ZWEIG_EGAL=1"* ]] && echo ja || echo nein)"
pruefe "Seitenzweig: sagt, dass nichts geschah" "ja" "$([[ ${B#*|} == *"NICHTS veraendert"* ]] && echo ja || echo nein)"

# 1c. Die Tuere oeffnet — und meldet sich
C=$(probe PLAINTEXT_SCRIPTS_ZWEIG_EGAL=1)
pruefe "Tuere: Rueckgabe 0 trotz Seitenzweig" "0"  "${C%%|*}"
pruefe "Tuere: warnt sichtbar"                "ja" "$([[ ${C#*|} == *"⚠"* && ${C#*|} == *"seitenzweig"* ]] && echo ja || echo nein)"
pruefe "Tuere: kein Abbruchtext"              "ja" "$([[ ${C#*|} != *"kommt nicht von 'master'"* ]] && echo ja || echo nein)"
# Ausgeschaltete Tuere (leer/0/false) laesst den Abbruch stehen — sonst oeffnet ein
# `PLAINTEXT_SCRIPTS_ZWEIG_EGAL=0` unbeabsichtigt die Sicherung.
D=$(probe PLAINTEXT_SCRIPTS_ZWEIG_EGAL=0)
pruefe "Tuere=0 oeffnet nicht"                "1"  "${D%%|*}"

# 1d. Hinter origin/master: Warnung, kein Abbruch — und ohne fetch gemessen
( cd "$TESTDIR/klon" && $G checkout -q master ) || exit 2
FREMD="$TESTDIR/fremd"
( $G clone -q "$TESTDIR/origin" "$FREMD" && cd "$FREMD" && echo "# weiter" >> lib.sh \
  && $G add -A && $G commit -qm zweit && $G push -q origin master ) || exit 2
( cd "$TESTDIR/klon" && $G fetch -q origin ) || exit 2
E=$(probe PLAINTEXT_SCRIPTS_ZWEIG_EGAL=)
pruefe "hinter origin/master: Rueckgabe 0"  "0"  "${E%%|*}"
pruefe "hinter origin/master: warnt"        "ja" "$([[ ${E#*|} == *"hinter dem zuletzt bekannten origin/master"* ]] && echo ja || echo nein)"
# Bewusste Entscheidung (Karte 1154): kein `git fetch` im Vorflug — ein Abbruch, weil das Netz
# klemmt, waere die falsche Art Strenge. Der Funktionskoerper darf also keinen fetch AUSFUEHREN;
# Kommentare und Meldungstexte duerfen das Wort tragen (die Warnung sagt "ohne fetch gemessen").
pruefe "kein git fetch in der Pruefung"     "ja" \
    "$([[ $(printf '%s' "$FN" | grep -v '^\s*#' | grep -v 'echo -e') != *"fetch"* ]] && echo ja || echo nein)"

# 1e. Kein git-Klon (Kopie ohne .git): Warnung, kein Abbruch
mkdir -p "$TESTDIR/kopie" && lib_schreiben "$TESTDIR/kopie"
F=$(cd "$TESTDIR/kopie" && bash -c 'source ./lib.sh; skript_klon_zweig_pruefen' 2>&1; )
FRC=$?
pruefe "kein git-Klon: Rueckgabe 0"         "0"  "$FRC"
pruefe "kein git-Klon: warnt"               "ja" "$([[ $F == *"kein git-Klon"* ]] && echo ja || echo nein)"

# ── Teil 2: Verdrahtung — die Pruefung muss VOR dem Wirksamen stehen ─────────────────────
Z_V_KLON=$(zeile_in lokal_vorflug 'skript_klon_zweig_pruefen')
Z_V_BRANCH=$(zeile_in lokal_vorflug 'git rev-parse --abbrev-ref HEAD')
pruefe "lokal_vorflug ruft die Pruefung"    "ja" "$([ -n "${Z_V_KLON:-}" ] && echo ja || echo nein)"
if [ -n "${Z_V_KLON:-}" ] && [ -n "${Z_V_BRANCH:-}" ]; then
    pruefe "lokal_vorflug: Klon-Pruefung als erstes" "ja" \
        "$([ "$Z_V_KLON" -lt "$Z_V_BRANCH" ] && echo ja || echo nein)"
fi
# ./build 6 rollt aus, OHNE lokal_vorflug zu durchlaufen — deshalb auch hier, und zwar vor
# dem NAS-Deploy-Lock und vor ensure_nas_reachable.
Z_P_KLON=$(zeile_in deploy_to_prod 'skript_klon_zweig_pruefen')
Z_P_NAS=$(zeile_in deploy_to_prod 'ensure_nas_reachable')
Z_P_LOCK=$(zeile_in deploy_to_prod 'deploy_lock_acquire')
pruefe "deploy_to_prod ruft die Pruefung"   "ja" "$([ -n "${Z_P_KLON:-}" ] && echo ja || echo nein)"
if [ -n "${Z_P_KLON:-}" ] && [ -n "${Z_P_NAS:-}" ] && [ -n "${Z_P_LOCK:-}" ]; then
    pruefe "deploy_to_prod: Pruefung VOR ensure_nas_reachable" "ja" \
        "$([ "$Z_P_KLON" -lt "$Z_P_NAS" ] && echo ja || echo nein)"
    pruefe "deploy_to_prod: Pruefung VOR deploy_lock_acquire"  "ja" \
        "$([ "$Z_P_KLON" -lt "$Z_P_LOCK" ] && echo ja || echo nein)"
fi
# In der CI checkt die Pipeline aus, was sie ausgecheckt hat (auch mal einen PR-Zweig oder einen
# losen HEAD) — die Zweigprüfung des lokalen Klons gilt dort nicht.
pruefe "deploy_to_prod: Pruefung nur ausserhalb der CI" "ja" \
    "$([[ $(koerper deploy_to_prod) == *'if [ "${CI:-}" != "true" ] && ! skript_klon_zweig_pruefen'* ]] && echo ja || echo nein)"
# Ein reiner Bau und `run` rollen nichts aus und dürfen nicht blockieren.
for FN_OHNE in do_build_snapshot do_run; do
    pruefe "$FN_OHNE ruft die Pruefung NICHT" "" "$(zeile_in "$FN_OHNE" 'skript_klon_zweig_pruefen')"
done

echo ""
if [ "$FEHLER" -eq 0 ]; then echo "ERGEBNIS: alle Faelle wie erwartet"; else echo "FEHLER"; fi
exit "$FEHLER"
