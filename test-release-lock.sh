#!/usr/bin/env bash
# test-release-lock.sh — stellt die Race bei der Release-Versionsrechnung NACH (30.08.2026).
#
# WORUM ES GEHT
#
# Bis zur Umstellung auf Woodpecker sorgte die GitHub-Concurrency-Gruppe (`deploy-<projekt>`)
# dafuer, dass je Repo hoechstens ein Release-Lauf gleichzeitig faehrt. Woodpecker kennt keine
# Concurrency-Gruppen. Ohne Ersatz rechnen zwei gleichzeitig gestartete Laeufe aus derselben
# POM-Version DIESELBE neue Nummer, bestehen beide die Kollisionspruefung gegen das Release-Repo
# (die Nummer ist ja noch nirgends veroeffentlicht), bauen beide — und erst der `git push` des
# zweiten wird abgelehnt. Bei plaintext-root sind das 24 Module fuer nichts.
#
# WARUM EIN LOCK ALLEIN NICHT REICHT
#
# CURRENT_VERSION wird vom build-Wrapper beim START gesetzt (init_versions). Ein Lauf, der eine
# halbe Stunde auf den Lock gewartet hat, haelt danach eine VERALTETE Nummer in der Hand und
# rechnet dieselbe Version noch einmal. Erst "Lock nehmen -> Stand nachziehen -> dann rechnen"
# schliesst die Race. Genau das prueft Fall B gegen Fall A.
#
# WIE GETESTET WIRD
#
# Echte Git-Repositories (ein bare-"origin" und zwei Klone = zwei Laeufe) und ein echtes,
# atomares `mkdir` fuer den Lock — nur `ssh` ist eine Attrappe, die das Kommando lokal
# ausfuehrt (Muster von test-backup-prod-db.sh), und `mvn` faellt absichtlich aus, damit
# get_pom_version seinen grep-Pfad nimmt. Der Lock liegt unter $TESTDIR/nas, NICHT auf dem
# echten NAS. Die zu testenden Funktionen werden aus der echten tui-build-logic.sh geholt.
#
# Aufruf:  ./test-release-lock.sh [pfad-zu-tui-build-logic.sh]
# shellcheck disable=SC2034  # Farben/DEPLOY_SERVER/IMAGE_NAME liest der per eval geladene Code
set -uo pipefail

SKRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/tui-build-logic.sh}"
[ -r "$SKRIPT" ] || { echo "nicht lesbar: $SKRIPT" >&2; exit 2; }

FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
           else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi; }

# ── Werkstatt ──────────────────────────────────────────────────────────────────────────
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

# Die Funktionen rufen blankes `git`. Auf dem Mac ist das PATH-git 2.23 (zu alt); /usr/bin/git
# ist 2.50. Das neuere der beiden kommt in einen eigenen bin-Ordner ganz vorn im PATH.
GIT_BIN="$(command -v git)"
if [ -x /usr/bin/git ]; then
    V_PATH=$("$GIT_BIN" --version | awk '{print $3}')
    V_USR=$(/usr/bin/git --version | awk '{print $3}')
    if [ "$(printf '%s\n%s\n' "$V_PATH" "$V_USR" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$V_USR" ]; then
        GIT_BIN=/usr/bin/git
    fi
fi
mkdir -p "$TESTDIR/bin"
ln -s "$GIT_BIN" "$TESTDIR/bin/git"
PATH="$TESTDIR/bin:$PATH"
export PATH
export GIT_AUTHOR_NAME=Attrappe GIT_AUTHOR_EMAIL=attrappe@example.invalid
export GIT_COMMITTER_NAME=Attrappe GIT_COMMITTER_EMAIL=attrappe@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

# ── Attrappen ──────────────────────────────────────────────────────────────────────────
BLUE=''; GREEN=''; RED=''; YELLOW=''; NC=''
DEPLOY_SERVER=attrappe
DEPLOY_PATH="$TESTDIR/nas"
IMAGE_NAME=testprojekt
mkdir -p "$DEPLOY_PATH"

# $1 = Server, Rest = Kommando — lokal ausfuehren, damit Quoting, && und Umleitung genau so
# wirken wie auf dem NAS. `mkdir` ist auch lokal atomar; die Race ist damit echt.
ssh() { shift; bash -c "$*"; }
# mvn faellt aus -> get_pom_version nimmt den grep-Pfad auf pom.xml.
mvn() { return 1; }
# Der NAS-Erreichbarkeitstest ist in den meisten Faellen "erreichbar" (Fall F setzt ihn um).
NAS_ANTWORTET=ja
ensure_nas_reachable() { [ "$NAS_ANTWORTET" = "ja" ]; }
export -f ssh mvn 2>/dev/null

# ── Die zu testenden Funktionen aus der echten Datei holen ─────────────────────────────
hole() {
    if grep -q "^$1() {\$" "$SKRIPT"; then
        sed -n "/^$1() {\$/,/^}\$/p" "$SKRIPT"
    else                                     # Einzeiler wie deploy_lock_pfad
        grep "^$1() {" "$SKRIPT"
    fi
}
for F in deploy_lock_pfad deploy_lock_acquire deploy_lock_release \
         release_lock_abbruch release_lock_nehmen release_lock_freigeben \
         release_stand_nachziehen compute_release_versions \
         get_pom_version get_release_version init_versions; do
    AUSSCHNITT="$(hole "$F")"
    if [ -z "$AUSSCHNITT" ]; then
        echo "  FEHL $F() nicht in $SKRIPT gefunden" >&2
        exit 2
    fi
    eval "$AUSSCHNITT"
done

# Konstanten wie im Skript, nur schnell genug fuer einen Test.
DEPLOY_LOCK_WAIT=60
DEPLOY_LOCK_STALE=3600
DEPLOY_LOCK_INTERVALL=1
DEPLOY_LOCK_HELD=""
DEPLOY_LOCK_TOKEN="test-$$"
RELEASE_LOCK_NAME="release-${IMAGE_NAME}"
LOCK_PFAD="$(deploy_lock_pfad "$RELEASE_LOCK_NAME")"
CURRENT_VERSION=""; RELEASE_VERSION=""; NEW_VERSION=""

# ── Ein Release-Lauf als Attrappe ──────────────────────────────────────────────────────
# Nimmt (optional) den Lock, wartet, zieht (nur mit Lock) den Stand nach, rechnet die Nummer,
# beansprucht sie mit Commit+Tag+Push und gibt den Lock frei — dieselbe Reihenfolge wie
# do_release/release_nummer_beanspruchen, nur ohne Maven-Build.
#   $1 Arbeitsverzeichnis  $2 Marke  $3 mit-lock (ja|nein)  $4 Haltezeit vor dem Push (s)
lauf() {
    local ARBEIT="$1" MARKE="$2" MIT_LOCK="$3" HALTEZEIT="$4"
    cd "$ARBEIT" || exit 1
    DEPLOY_LOCK_TOKEN="lauf${MARKE}-$$"       # jeder Lauf hat seinen eigenen Besitzer-Token
    DEPLOY_LOCK_HELD=""
    {
        # Wie der build-Wrapper beim Start: CURRENT_VERSION JETZT lesen. Das ist die Nummer,
        # die nach einer Wartezeit veraltet waere.
        init_versions
        echo "start: CURRENT_VERSION=$CURRENT_VERSION"
        if [ "$MIT_LOCK" = "ja" ]; then
            release_lock_nehmen || exit 1
            # DER KERN DES FIX: nach dem Warten den Stand neu ziehen, dann erst rechnen.
            release_stand_nachziehen master || { release_lock_freigeben; exit 1; }
        fi
        local NEU REST
        read -r NEU REST <<< "$(compute_release_versions "$CURRENT_VERSION" 2)"
        echo "$NEU" > "$TESTDIR/nummer.$MARKE"
        echo "rechnet: $CURRENT_VERSION -> $NEU (naechster SNAPSHOT $REST)"
        sleep "$HALTEZEIT"
        printf '<project>\n  <version>%s</version>\n</project>\n' "$NEU" > pom.xml
        git commit -aqm "Release version $NEU"
        git tag -a "$NEU" -m "$NEU"
        if git push -q origin master && git push -q origin "refs/tags/$NEU"; then
            echo ok > "$TESTDIR/push.$MARKE"
        else
            echo abgelehnt > "$TESTDIR/push.$MARKE"
        fi
        echo "push: $(cat "$TESTDIR/push.$MARKE")"
        [ "$MIT_LOCK" = "ja" ] && release_lock_freigeben
    } > "$TESTDIR/protokoll.$MARKE" 2>&1
    exit 0
}

# Frischer Ausgangszustand: bare-origin mit 1.0.0-SNAPSHOT und zwei Klone.
buehne_aufbauen() {
    rm -rf "$TESTDIR/origin.git" "$TESTDIR/lauf1" "$TESTDIR/lauf2" \
           "$TESTDIR"/nummer.* "$TESTDIR"/push.* "$TESTDIR"/protokoll.*
    rm -rf "$LOCK_PFAD"
    git init -q --bare "$TESTDIR/origin.git"
    git --git-dir="$TESTDIR/origin.git" symbolic-ref HEAD refs/heads/master
    git init -q "$TESTDIR/saat"
    (
        cd "$TESTDIR/saat" || exit 1
        git symbolic-ref HEAD refs/heads/master
        printf '<project>\n  <version>1.0.0-SNAPSHOT</version>\n</project>\n' > pom.xml
        git add pom.xml && git commit -qm "Start"
        git remote add origin "$TESTDIR/origin.git" && git push -q origin master
    )
    rm -rf "$TESTDIR/saat"
    git clone -q "$TESTDIR/origin.git" "$TESTDIR/lauf1"
    git clone -q "$TESTDIR/origin.git" "$TESTDIR/lauf2"
}

# Die beiden Laufprotokolle nebeneinander ausgeben — das ist der eigentliche Nachweis.
protokolle_zeigen() {
    local M
    for M in 1 2; do
        echo "  ── Lauf ${M} ───────────────────────────────────────────────"
        sed 's/^/     /' "$TESTDIR/protokoll.$M" 2>/dev/null
    done
}

race_fahren() {
    local MIT_LOCK="$1"
    buehne_aufbauen
    # Lauf 1 startet zuerst und haelt 3 s (das waere der Build). Lauf 2 startet 1 s spaeter —
    # mit Lock muss er warten, ohne Lock rechnet er parallel.
    ( lauf "$TESTDIR/lauf1" 1 "$MIT_LOCK" 3 ) &
    local P1=$!
    sleep 1
    ( lauf "$TESTDIR/lauf2" 2 "$MIT_LOCK" 0 ) &
    local P2=$!
    wait "$P1" "$P2"
}

echo "== Fall A: Gegenprobe — OHNE Lock (Zustand vor dem Fix) ==================="
race_fahren nein
protokolle_zeigen
A1=$(cat "$TESTDIR/nummer.1" 2>/dev/null); A2=$(cat "$TESTDIR/nummer.2" 2>/dev/null)
A_PUSH1=$(cat "$TESTDIR/push.1" 2>/dev/null); A_PUSH2=$(cat "$TESTDIR/push.2" 2>/dev/null)
printf '  Lauf 1 rechnet %s (push %s), Lauf 2 rechnet %s (push %s)\n' "$A1" "$A_PUSH1" "$A2" "$A_PUSH2"
pruefe "beide Laeufe rechnen DIESELBE Nummer" "ja" "$([ "$A1" = "$A2" ] && echo ja || echo nein)"
pruefe "beide rechnen 1.1.0"                  "1.1.0 1.1.0" "$A1 $A2"
pruefe "ein Push wird abgelehnt (Build umsonst)" "ja" \
       "$([ "$A_PUSH1 $A_PUSH2" != "ok ok" ] && echo ja || echo nein)"

echo "== Fall B: MIT Release-Lock ==============================================="
race_fahren ja
protokolle_zeigen
B1=$(cat "$TESTDIR/nummer.1" 2>/dev/null); B2=$(cat "$TESTDIR/nummer.2" 2>/dev/null)
B_PUSH1=$(cat "$TESTDIR/push.1" 2>/dev/null); B_PUSH2=$(cat "$TESTDIR/push.2" 2>/dev/null)
printf '  Lauf 1 rechnet %s (push %s), Lauf 2 rechnet %s (push %s)\n' "$B1" "$B_PUSH1" "$B2" "$B_PUSH2"
pruefe "Lauf 2 hat auf den Lock gewartet" "ja" \
       "$(grep -q 'Deploy-Lock .* belegt von' "$TESTDIR/protokoll.2" && echo ja || echo nein)"
pruefe "Lauf 2 hat danach den Stand nachgezogen" "ja" \
       "$(grep -q 'liegt hinter origin' "$TESTDIR/protokoll.2" && echo ja || echo nein)"
pruefe "die Nummern sind VERSCHIEDEN" "ja" "$([ "$B1" != "$B2" ] && echo ja || echo nein)"
pruefe "Lauf 2 bekommt die naechsthoehere Nummer" "1.1.0 1.2.0" "$B1 $B2"
pruefe "BEIDE Pushes gehen durch (kein Build umsonst)" "ok ok" "$B_PUSH1 $B_PUSH2"
pruefe "Lock am Ende frei" "nein" "$([ -d "$LOCK_PFAD" ] && echo ja || echo nein)"

echo "== Fall C: verwaister Lock (abgestuerzter Vorgaenger) ====================="
rm -rf "$LOCK_PFAD"; mkdir -p "$LOCK_PFAD"
echo "geist-1234 $(( $(date +%s) - DEPLOY_LOCK_STALE - 60 )) 1.0.0" > "$LOCK_PFAD/owner"
DEPLOY_LOCK_HELD=""; DEPLOY_LOCK_TOKEN="uebernehmer-$$"
# NICHT in $(...): der Lock-Besitz steht in DEPLOY_LOCK_HELD, und eine Subshell wuerde ihn
# beim Zurueckkehren verlieren — die spaetere Freigabe waere dann wirkungslos.
release_lock_nehmen > "$TESTDIR/fall-c.log" 2>&1; C_RC=$?
C_AUSGABE=$(cat "$TESTDIR/fall-c.log")
pruefe "verwaister Lock wird uebernommen" "0" "$C_RC"
pruefe "und die Uebernahme wird gemeldet" "ja" \
       "$(printf '%s' "$C_AUSGABE" | grep -q 'Verwaister Deploy-Lock' && echo ja || echo nein)"
pruefe "der neue Besitzer steht drin" "ja" \
       "$(grep -q "^uebernehmer-$$ " "$LOCK_PFAD/owner" && echo ja || echo nein)"
release_lock_freigeben >/dev/null 2>&1
pruefe "danach wieder frei" "nein" "$([ -d "$LOCK_PFAD" ] && echo ja || echo nein)"

echo "== Fall C2: fremder, FRISCHER Lock wird nicht uebernommen ================="
rm -rf "$LOCK_PFAD"; mkdir -p "$LOCK_PFAD"
echo "fremder-999 $(date +%s) 1.0.0" > "$LOCK_PFAD/owner"
DEPLOY_LOCK_HELD=""; DEPLOY_LOCK_TOKEN="wartender-$$"
DEPLOY_LOCK_WAIT=2
C2_AUSGABE=$(release_lock_nehmen 2>&1); C2_RC=$?
DEPLOY_LOCK_WAIT=60
pruefe "Abbruch nach DEPLOY_LOCK_WAIT statt Diebstahl" "1" "$C2_RC"
pruefe "der fremde Besitzer steht noch drin" "ja" \
       "$(grep -q '^fremder-999 ' "$LOCK_PFAD/owner" && echo ja || echo nein)"
rm -rf "$LOCK_PFAD"

echo "== Fall D: Fehlerfall — Freigabe trotz Abbruch des gesperrten Abschnitts =="
# Genau das Muster aus do_release: nehmen -> Abschnitt -> Rueckgabewert merken -> freigeben.
DEPLOY_LOCK_HELD=""; DEPLOY_LOCK_TOKEN="fehlerfall-$$"
abschnitt_der_scheitert() { return 1; }
release_lock_nehmen >/dev/null 2>&1
D_GEHALTEN=$([ -d "$LOCK_PFAD" ] && echo ja || echo nein)
abschnitt_der_scheitert
D_RC=$?
release_lock_freigeben >/dev/null 2>&1
pruefe "Lock war waehrend des Abschnitts gehalten" "ja" "$D_GEHALTEN"
pruefe "Abschnitt meldet Fehler"                   "1"  "$D_RC"
pruefe "Lock ist trotzdem frei"                    "nein" "$([ -d "$LOCK_PFAD" ] && echo ja || echo nein)"

echo "== Fall E: harter Abbruch (SIGTERM) waehrend der Versionsvergabe =========="
rm -rf "$LOCK_PFAD"
(
    DEPLOY_LOCK_HELD=""; DEPLOY_LOCK_TOKEN="abbruch-$$-$RANDOM"
    release_lock_nehmen
    sleep 30
) > "$TESTDIR/fall-e.log" 2>&1 & E_PID=$!
for _ in $(seq 1 40); do [ -d "$LOCK_PFAD" ] && break; sleep 0.25; done
E_GEHALTEN=$([ -d "$LOCK_PFAD" ] && echo ja || echo nein)
kill -TERM "$E_PID" 2>/dev/null
wait "$E_PID" 2>/dev/null
for _ in $(seq 1 40); do [ -d "$LOCK_PFAD" ] || break; sleep 0.25; done
pruefe "Lock war vor dem Abbruch gesetzt" "ja" "$E_GEHALTEN"
pruefe "INT/TERM-Trap gibt den Lock frei"  "nein" "$([ -d "$LOCK_PFAD" ] && echo ja || echo nein)"
pruefe "und meldet den Abbruch"            "ja" \
       "$(grep -q 'Abbruch waehrend der Versionsvergabe' "$TESTDIR/fall-e.log" && echo ja || echo nein)"

echo "== Fall F: NAS nicht erreichbar =========================================="
rm -rf "$LOCK_PFAD"
NAS_ANTWORTET=nein
DEPLOY_LOCK_HELD=""; DEPLOY_LOCK_TOKEN="ohne-nas-$$"
F_AUSGABE=$(release_lock_nehmen 2>&1); F_RC=$?
pruefe "ohne NAS bricht der Release ab (kein stiller Rueckfall)" "1" "$F_RC"
pruefe "und sagt warum"  "ja" \
       "$(printf '%s' "$F_AUSGABE" | grep -q 'ohne NAS kein Release' && echo ja || echo nein)"
pruefe "und nennt den bewussten Ausweg" "ja" \
       "$(printf '%s' "$F_AUSGABE" | grep -q 'RELEASE_LOCK_OHNE_NAS=true' && echo ja || echo nein)"
F2_AUSGABE=$(RELEASE_LOCK_OHNE_NAS=true release_lock_nehmen 2>&1); F2_RC=$?
pruefe "mit RELEASE_LOCK_OHNE_NAS=true laeuft er weiter" "0" "$F2_RC"
pruefe "aber laut und mit benanntem Risiko" "ja" \
       "$(printf '%s' "$F2_AUSGABE" | grep -q 'dieselbe' && echo ja || echo nein)"
release_lock_freigeben >/dev/null 2>&1
NAS_ANTWORTET=ja

echo "== Fall G: Aufbau im Skript (Waechter gegen spaeteres Verrutschen) ========"
# Reine Zeilennummern taugen hier nicht mehr: der gesperrte Abschnitt steht in einer eigenen
# Funktion, die WEITER UNTEN in der Datei definiert ist. Geprueft wird deshalb je Funktion.
BLOCK_DO=$(sed -n '/^do_release() {/,/^}/p' "$SKRIPT")
BLOCK_NUMMER=$(sed -n '/^release_nummer_beanspruchen() {/,/^}/p' "$SKRIPT")
BLOCK_BAU=$(sed -n '/^do_release_bauen_und_veroeffentlichen() {/,/^}/p' "$SKRIPT")
# Zeilennummer INNERHALB eines Blocks (0 = nicht enthalten).
in_block() { printf '%s\n' "$1" | grep -n -- "$2" | head -1 | cut -d: -f1; }

G_NEHMEN=$(in_block "$BLOCK_DO" 'release_lock_nehmen')
G_ABSCHNITT=$(in_block "$BLOCK_DO" '^    release_nummer_beanspruchen$')
G_FREI=$(in_block "$BLOCK_DO" 'release_lock_freigeben')
G_BAUEN=$(in_block "$BLOCK_DO" 'do_release_bauen_und_veroeffentlichen')
printf '  in do_release: nehmen %s | Abschnitt %s | freigeben %s | bauen %s\n' \
       "${G_NEHMEN:-0}" "${G_ABSCHNITT:-0}" "${G_FREI:-0}" "${G_BAUEN:-0}"
pruefe "do_release nimmt den Lock" "ja" "$([ -n "$G_NEHMEN" ] && echo ja || echo nein)"
pruefe "Abschnitt laeuft NACH dem Nehmen" "ja" \
       "$([ "${G_NEHMEN:-0}" -lt "${G_ABSCHNITT:-0}" ] 2>/dev/null && echo ja || echo nein)"
pruefe "Freigabe steht direkt NACH dem Abschnitt" "ja" \
       "$([ "${G_ABSCHNITT:-0}" -lt "${G_FREI:-0}" ] 2>/dev/null && echo ja || echo nein)"
pruefe "Build/Veroeffentlichung erst NACH der Freigabe" "ja" \
       "$([ "${G_FREI:-0}" -lt "${G_BAUEN:-0}" ] 2>/dev/null && echo ja || echo nein)"
pruefe "do_release rechnet die Version NICHT mehr selbst" "ja" \
       "$(printf '%s\n' "$BLOCK_DO" | grep -q 'compute_release_versions' && echo nein || echo ja)"

G_NACHZIEHEN=$(in_block "$BLOCK_NUMMER" 'release_stand_nachziehen')
G_RECHNEN=$(in_block "$BLOCK_NUMMER" 'compute_release_versions')
G_KOLLISION=$(in_block "$BLOCK_NUMMER" 'RELEASE_REPO_URL')
G_TAGPUSH=$(in_block "$BLOCK_NUMMER" 'refs/tags/${NEW_VERSION}')
printf '  im gesperrten Abschnitt: nachziehen %s | rechnen %s | Kollisionspruefung %s | Tag-Push %s\n' \
       "${G_NACHZIEHEN:-0}" "${G_RECHNEN:-0}" "${G_KOLLISION:-0}" "${G_TAGPUSH:-0}"
pruefe "erst nachziehen, dann rechnen (sonst waere der Lock wirkungslos)" "ja" \
       "$([ "${G_NACHZIEHEN:-0}" -lt "${G_RECHNEN:-0}" ] 2>/dev/null && echo ja || echo nein)"
pruefe "Kollisionspruefung liegt im gesperrten Abschnitt" "ja" \
       "$([ "${G_RECHNEN:-0}" -lt "${G_KOLLISION:-0}" ] 2>/dev/null && echo ja || echo nein)"
pruefe "der Abschnitt endet mit dem Tag-Push" "ja" \
       "$([ "${G_KOLLISION:-0}" -lt "${G_TAGPUSH:-0}" ] 2>/dev/null && echo ja || echo nein)"
pruefe "der Build liegt NICHT im gesperrten Abschnitt" "ja" \
       "$(printf '%s\n' "$BLOCK_NUMMER" | grep -q 'mvn clean deploy' && echo nein || echo ja)"
pruefe "Build und SNAPSHOT-Push liegen im ungesperrten Teil" "ja" \
       "$(printf '%s\n' "$BLOCK_BAU" | grep -q 'mvn clean deploy' \
          && printf '%s\n' "$BLOCK_BAU" | grep -q 'Pushing next SNAPSHOT commit' && echo ja || echo nein)"
pruefe "beide Nachziehwege vorhanden (CI und lokal)" "ja" \
       "$(printf '%s\n' "$BLOCK_NUMMER" | grep -q 'release_stand_nachziehen' \
          && printf '%s\n' "$BLOCK_NUMMER" | grep -q 'lokal_vorflug' && echo ja || echo nein)"

echo
if [ "$FEHLER" = "0" ]; then echo "ERGEBNIS: alle Faelle wie erwartet"; else echo "ERGEBNIS: FEHLER"; fi
exit "$FEHLER"
