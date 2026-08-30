#!/usr/bin/env bash
# test-root-autobump.sh — bewacht die Vollstaendigkeitspruefung (Massnahme 4, 29.08.2026):
# ci/reposilite-release.sh, ci/root-autobump.sh (detect/apply) und die Selbstkontrolle
# release_vollstaendig_pruefen() aus tui-build-logic.sh.
#
# WORUM ES GEHT
#
# Ein root-Release laedt 24 Module ueber rund 15 Minuten hoch; die <release>-Angabe der
# Parent-Metadata steht schon nach dem ersten. Ein Auto-Bump in diesem Fenster sah ein halbes
# Release (Verify rot, unaufloesbarer PR). Seit Massnahme 4 gilt eine Version erst als
# veroeffentlicht, wenn jedes Modul aus ihrem Parent-POM als <modul>-<version>.pom da ist.
# `deployAtEnd=true` (zwei Deploy-Ausfuehrungen -> 409) war der gescheiterte erste Versuch.
#
# Das Repo ist hier ein Verzeichnis (file://) — kein Netz, keine Attrappe fuer curl: das Skript
# laeuft echt, mit denselben Pfaden wie gegen maven.plaintext.ch. Die Faelle:
#   A  halbes Release (ein Modul fehlt)  -> detect: bump=false, Exit 0, Meldung "unvollstaendig";
#                                            apply: verweigert, pom unveraendert
#   B  Release komplett                  -> detect: bump=true; apply: parent + Property gebumpt
#   C  Parent-POM noch gar nicht da       -> detect: bump=false, Exit 0
#   D  Consumer braucht ein Artefakt, das root nicht (mehr) hat -> harter Abbruch (kein Zeitfenster)
#   E  BUMP_IGNORIERE_MODULE nimmt ein bewusst nicht deploytes Modul aus der Pruefung
#   F  Modulliste: auskommentierte Module und Module in <profiles> zaehlen nicht
#   G  nicht pruefbar (5xx) zaehlt wie fehlend und wird mit HTTP-Code gemeldet
#   H  Selbstkontrolle im Release-Job: nie fatal, Verzeichnis -> artifactId, ::warning in der CI
#
# Aufruf:  ./test-root-autobump.sh
set -uo pipefail

HIER="$(cd "$(dirname "$0")" && pwd)"
SKRIPT="$HIER/ci/root-autobump.sh"
LIB="$HIER/ci/reposilite-release.sh"
TUI="$HIER/tui-build-logic.sh"
for f in "$SKRIPT" "$LIB" "$TUI"; do [ -r "$f" ] || { echo "nicht lesbar: $f" >&2; exit 2; }; done

FEHLER=0
pruefe() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
           else printf '  FEHL %s\n       erwartet: %s\n       erhalten: %s\n' "$1" "$2" "$3"; FEHLER=1; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$T/repo"; G="$REPO/ch/plaintext"
export ROOT_MAVEN_REPO="file://$REPO"
export POM_FILE="$T/pom.xml"
export GITHUB_OUTPUT="$T/gh-output"

# ── Repo-Attrappe im Dateisystem ───────────────────────────────────────────
pom_ablegen() {   # $1 = artifactId  $2 = Version  [$3 = Inhalt]
    mkdir -p "$G/$1/$2"
    printf '%s\n' "${3:-<project><artifactId>$1</artifactId><version>$2</version></project>}" > "$G/$1/$2/$1-$2.pom"
}
parent_pom() {   # $1 = Version, $2.. = Module
    local v="$1"; shift
    local m mods=""
    for m in "$@"; do mods="${mods}        <module>${m}</module>
"; done
    cat <<EOF
<project>
    <artifactId>plaintext-root-parent</artifactId>
    <version>${v}</version>
    <!-- <module>plaintext-root-auskommentiert</module> -->
    <!--
        mehrzeilig, mit -> im Text
        <module>plaintext-root-mehrzeilig</module>
    -->
    <modules>
${mods}    </modules>
    <profiles>
        <profile>
            <id>nur-manuell</id>
            <modules><module>plaintext-root-profilmodul</module></modules>
        </profile>
    </profiles>
</project>
EOF
}
metadata() {   # $1 = release, $2.. = alle Versionen
    local r="$1"; shift
    { echo '<metadata><artifactId>plaintext-root-parent</artifactId><versioning>'
      echo "<release>$r</release><versions>"
      for v in "$@"; do echo "<version>$v</version>"; done
      echo '</versions></versioning></metadata>'; } > "$G/plaintext-root-parent/maven-metadata.xml"
}
consumer_pom() {   # $1 = gepinnte Version, $2.. = benoetigte Artefakte
    local v="$1"; shift
    { echo '<project>'
      echo "  <parent><groupId>ch.plaintext</groupId><artifactId>plaintext-root-parent</artifactId><version>$v</version></parent>"
      echo '  <artifactId>plaintext-app-parent</artifactId>'
      echo "  <properties><plaintext-root.version>$v</plaintext-root.version></properties>"
      echo '  <dependencies>'
      for a in "$@"; do
        echo "    <dependency><groupId>ch.plaintext</groupId><artifactId>$a</artifactId><version>\${plaintext-root.version}</version></dependency>"
      done
      echo '  </dependencies>'
      echo '</project>'; } > "$POM_FILE"
}
MODULE="plaintext-root-common plaintext-root-web plaintext-admin-cron"
# 1.636.0: komplett.  1.638.0: Parent + zwei von drei Modulen (das halbe Release).
# shellcheck disable=SC2086  # MODULE ist absichtlich eine Wortliste
pom_ablegen plaintext-root-parent 1.636.0 "$(parent_pom 1.636.0 $MODULE)"
for m in $MODULE; do pom_ablegen "$m" 1.636.0; done
# shellcheck disable=SC2086
pom_ablegen plaintext-root-parent 1.638.0 "$(parent_pom 1.638.0 $MODULE)"
pom_ablegen plaintext-root-common 1.638.0
pom_ablegen plaintext-root-web 1.638.0
metadata 1.638.0 1.636.0 1.638.0
consumer_pom 1.636.0 plaintext-root-common plaintext-root-web

lauf() {   # $1.. = Argumente fuer das Skript; setzt AUS (stdout+stderr) und RC
    : > "$GITHUB_OUTPUT"
    AUS="$(bash "$SKRIPT" "$@" 2>&1)"; RC=$?
}
ausgabe() { grep -m1 "^$1=" "$GITHUB_OUTPUT" | cut -d= -f2-; }
pin() { grep -o '<plaintext-root\.version>[^<]*<' "$POM_FILE" | sed 's/.*>//;s/<$//'; }
parent() { awk '/<parent>/{p=1} p&&/<version>/{gsub(/.*<version>|<\/version>.*/,""); print; exit}' "$POM_FILE"; }

echo "== A: halbes Release (plaintext-admin-cron 1.638.0 fehlt) =================="
lauf detect
pruefe "detect: Exit 0 (kein Fehler, nur warten)"     "0"                    "$RC"
pruefe "detect: bump=false"                           "false"                "$(ausgabe bump)"
pruefe "detect: vollstaendig=false"                   "false"                "$(ausgabe vollstaendig)"
pruefe "detect: fehlend nennt das Modul"              "plaintext-admin-cron" "$(ausgabe fehlend)"
pruefe "detect: latest bleibt sichtbar"               "1.638.0"              "$(ausgabe latest)"
pruefe "detect: Meldung 'noch unvollstaendig ... naechster Lauf'" "ja" \
       "$(printf '%s' "$AUS" | grep -q 'Release 1.638.0 noch unvollstaendig (fehlt: plaintext-admin-cron), naechster Lauf' && echo ja || echo nein)"
pruefe "detect: kein ::error"                         "0"                    "$(printf '%s' "$AUS" | grep -c '::error' || true)"
lauf apply 1.638.0
pruefe "apply: verweigert (Exit != 0)"                "ja"                   "$([ "$RC" -ne 0 ] && echo ja || echo nein)"
pruefe "apply: nennt das fehlende Modul"              "ja" \
       "$(printf '%s' "$AUS" | grep -q 'unvollstaendig (fehlt: plaintext-admin-cron)' && echo ja || echo nein)"
pruefe "apply: pom unveraendert (Pin)"                "1.636.0"              "$(pin)"
pruefe "apply: pom unveraendert (parent)"             "1.636.0"              "$(parent)"

echo "== B: Release komplett ======================================================="
pom_ablegen plaintext-admin-cron 1.638.0
lauf detect
pruefe "detect: Exit 0"                               "0"                    "$RC"
pruefe "detect: bump=true"                            "true"                 "$(ausgabe bump)"
pruefe "detect: vollstaendig=true"                    "true"                 "$(ausgabe vollstaendig)"
pruefe "detect: fehlend leer"                         ""                     "$(ausgabe fehlend)"
pruefe "detect: behind=1"                             "1"                    "$(ausgabe behind)"
lauf apply 1.638.0
pruefe "apply: Exit 0"                                "0"                    "$RC"
pruefe "apply: Pin gebumpt"                           "1.638.0"              "$(pin)"
pruefe "apply: parent gebumpt"                        "1.638.0"              "$(parent)"
lauf detect
pruefe "detect danach: kein Bump mehr (Exit 1)"       "1"                    "$RC"
pruefe "detect danach: bump=false"                    "false"                "$(ausgabe bump)"
pruefe "detect danach: vollstaendig=true (keine Pruefung noetig, nichts behauptet)" "true" "$(ausgabe vollstaendig)"

echo "== C: Metadata kennt 1.640.0, Parent-POM noch nicht da ======================"
metadata 1.640.0 1.636.0 1.638.0 1.640.0
lauf detect
pruefe "detect: Exit 0"                               "0"                    "$RC"
pruefe "detect: bump=false"                           "false"                "$(ausgabe bump)"
pruefe "detect: Meldung 'Parent-POM nicht abrufbar'"  "ja" \
       "$(printf '%s' "$AUS" | grep -q 'Parent-POM nicht abrufbar' && echo ja || echo nein)"
lauf apply 1.640.0
pruefe "apply: verweigert"                            "ja"                   "$([ "$RC" -ne 0 ] && echo ja || echo nein)"
pruefe "apply: Pin unveraendert"                      "1.638.0"              "$(pin)"
metadata 1.638.0 1.636.0 1.638.0

echo "== D: Consumer braucht ein Artefakt, das root nicht hat ======================"
# Release 1.638.0 ist komplett — das fehlende Artefakt ist also KEIN Zeitfenster: harter Abbruch.
consumer_pom 1.636.0 plaintext-root-common plaintext-admin-verschwunden
lauf detect
pruefe "detect: Abbruch (Exit != 0)"                  "ja"                   "$([ "$RC" -ne 0 ] && echo ja || echo nein)"
pruefe "detect: ::error nennt das Artefakt"           "ja" \
       "$(printf '%s' "$AUS" | grep -q '::error::.*plaintext-admin-verschwunden.*NICHT publiziert' && echo ja || echo nein)"
consumer_pom 1.636.0 plaintext-root-common plaintext-root-web

echo "== E: BUMP_IGNORIERE_MODULE ================================================="
rm "$G/plaintext-admin-cron/1.638.0/plaintext-admin-cron-1.638.0.pom"
lauf detect
pruefe "ohne Ausnahme: bump=false"                    "false"                "$(ausgabe bump)"
BUMP_IGNORIERE_MODULE="plaintext-admin-cron" lauf detect
pruefe "mit Ausnahme: bump=true"                      "true"                 "$(ausgabe bump)"
pruefe "mit Ausnahme: vollstaendig=true"              "true"                 "$(ausgabe vollstaendig)"
pom_ablegen plaintext-admin-cron 1.638.0

echo "== F/G: Bibliothek direkt =================================================="
# shellcheck source=ci/reposilite-release.sh
. "$LIB"
pruefe "Modulliste: nur echte Module, keine Kommentare, keine Profile" \
       "plaintext-root-common plaintext-root-web plaintext-admin-cron" \
       "$(reposilite_module_liste "$ROOT_MAVEN_REPO" ch/plaintext plaintext-root-parent 1.638.0 | tr '\n' ' ' | sed 's/ $//')"
pruefe "Modulliste: Parent fehlt -> Rueckgabe 1" "1" \
       "$(reposilite_module_liste "$ROOT_MAVEN_REPO" ch/plaintext plaintext-root-parent 9.9.9 >/dev/null; echo $?)"
pruefe "vorhanden: file:// da"                        "0" "$(reposilite_vorhanden "$(reposilite_pom_url "$ROOT_MAVEN_REPO" ch/plaintext plaintext-root-web 1.638.0)" >/dev/null; echo $?)"
pruefe "vorhanden: file:// fehlt"                     "1" "$(reposilite_vorhanden "$(reposilite_pom_url "$ROOT_MAVEN_REPO" ch/plaintext plaintext-root-web 9.9.9)" >/dev/null; echo $?)"
pruefe "release_fehlend: komplett -> 0, leer"         "0:" \
       "$(f="$(reposilite_release_fehlend "$ROOT_MAVEN_REPO" ch/plaintext plaintext-root-parent 1.638.0)"; echo "$?:$f")"
pruefe "release_fehlend: 1.636.0 komplett"            "0:" \
       "$(f="$(reposilite_release_fehlend "$ROOT_MAVEN_REPO" ch/plaintext plaintext-root-parent 1.636.0)"; echo "$?:$f")"
rm "$G/plaintext-root-web/1.638.0/plaintext-root-web-1.638.0.pom"
pruefe "release_fehlend: eines fehlt -> 1 + Name"     "1:plaintext-root-web" \
       "$(f="$(reposilite_release_fehlend "$ROOT_MAVEN_REPO" ch/plaintext plaintext-root-parent 1.638.0)"; echo "$?:$f")"
pruefe "release_fehlend: Parent fehlt -> 2"           "2" \
       "$(reposilite_release_fehlend "$ROOT_MAVEN_REPO" ch/plaintext plaintext-root-parent 9.9.9 >/dev/null; echo $?)"
pruefe "fehlend_text: unvollstaendig"                 "Release 1.638.0 noch unvollstaendig (fehlt: plaintext-root-web)" \
       "$(reposilite_fehlend_text 1 1.638.0 plaintext-root-web)"
# G: nicht pruefbar (5xx) — die Attrappe antwortet fuer plaintext-root-web mit 503
reposilite_vorhanden() { case "$1" in *plaintext-root-web*) echo 503; return 2 ;; *) echo 200; return 0 ;; esac; }
pruefe "nicht pruefbar zaehlt wie fehlend, mit HTTP-Code" "1:plaintext-root-web (HTTP 503)" \
       "$(f="$(reposilite_release_fehlend "$ROOT_MAVEN_REPO" ch/plaintext plaintext-root-parent 1.638.0)"; echo "$?:$f")"
unset -f reposilite_vorhanden
# shellcheck source=ci/reposilite-release.sh
. "$LIB"
pom_ablegen plaintext-root-web 1.638.0

echo "== H: Selbstkontrolle im Release-Job (tui-build-logic.sh) ==================="
# Die Funktion aus dem Skript schneiden; das ganze tui-build-logic.sh verlangt build-conf.txt.
eval "$(sed -n '/^release_vollstaendig_pruefen() {/,/^}/p' "$TUI")"
pruefe "Funktion gefunden" "ja" "$(type release_vollstaendig_pruefen >/dev/null 2>&1 && echo ja || echo nein)"
# Quellbaum-Attrappe: Modulverzeichnis != artifactId (Verzeichnis "web", artifactId plaintext-root-web)
Q="$T/quelle"; mkdir -p "$Q/plaintext-root-common" "$Q/web" "$Q/plaintext-admin-cron"
printf '<project><modules><module>plaintext-root-common</module></modules></project>\n' > "$Q/pom.xml"
printf '<project><parent><artifactId>plaintext-root-parent</artifactId></parent><artifactId>plaintext-root-web</artifactId></project>\n' > "$Q/web/pom.xml"
# shellcheck disable=SC2086
pom_ablegen plaintext-root-parent 1.639.0 "$(parent_pom 1.639.0 plaintext-root-common web plaintext-admin-cron)"
pom_ablegen plaintext-root-common 1.639.0; pom_ablegen plaintext-root-web 1.639.0; pom_ablegen plaintext-admin-cron 1.639.0
# shellcheck disable=SC2034  # Farben liest die per eval geladene Funktion
RED='' GREEN='' YELLOW='' NC=''
export MVN_RELEASE_DEPLOY=true RELEASE_REPO_URL="$ROOT_MAVEN_REPO" REL_GROUP=ch/plaintext REL_ARTIFACT=plaintext-root-parent
AUS="$(cd "$Q" && CI='' release_vollstaendig_pruefen 1.639.0 2>&1)"; RC=$?
pruefe "komplett: return 0"                           "0" "$RC"
pruefe "komplett: gruene Zeile mit Modulzahl"         "ja" "$(printf '%s' "$AUS" | grep -q 'Release 1.639.0 vollstaendig im Release-Repo (3 Module)' && echo ja || echo nein)"
rm "$G/plaintext-root-web/1.639.0/plaintext-root-web-1.639.0.pom"
AUS="$(cd "$Q" && CI='' release_vollstaendig_pruefen 1.639.0 2>&1)"; RC=$?
pruefe "unvollstaendig: trotzdem return 0 (nie fatal)" "0" "$RC"
pruefe "unvollstaendig: nennt die artifactId (nicht das Verzeichnis)" "ja" \
       "$(printf '%s' "$AUS" | grep -q 'UNVOLLSTAENDIG — es fehlt: plaintext-root-web' && echo ja || echo nein)"
pruefe "unvollstaendig: ohne CI keine ::warning"      "0" "$(printf '%s' "$AUS" | grep -c '::warning' || true)"
AUS="$(cd "$Q" && CI=true release_vollstaendig_pruefen 1.639.0 2>&1)"; RC=$?
pruefe "unvollstaendig, CI: ::warning-Annotation"     "ja" \
       "$(printf '%s' "$AUS" | grep -q '^::warning title=Release 1.639.0 unvollstaendig::fehlt in .*plaintext-root-web' && echo ja || echo nein)"
AUS="$(cd "$Q" && MVN_RELEASE_DEPLOY=false release_vollstaendig_pruefen 1.639.0 2>&1)"; RC=$?
pruefe "ohne mvn deploy: nichts zu pruefen, still"    "0:" "$RC:$AUS"
AUS="$(cd "$Q" && CI='' release_vollstaendig_pruefen 9.9.9 2>&1)"; RC=$?
pruefe "Parent fehlt: return 0, rote Zeile"           "0:ja" "$RC:$(printf '%s' "$AUS" | grep -q 'Parent-POM plaintext-root-parent-9.9.9.pom nicht im Release-Repo' && echo ja || echo nein)"

echo "== Verdrahtung ============================================================="
pruefe "root-autobump.sh sourct die Bibliothek" "ja" "$(grep -q 'reposilite-release.sh' "$SKRIPT" && echo ja || echo nein)"
pruefe "tui-build-logic.sh sourct die Bibliothek" "ja" "$(grep -q 'ci/reposilite-release.sh' "$TUI" && echo ja || echo nein)"
# Seit dem Release-Lock (30.08.2026) steht der Build nicht mehr in do_release selbst, sondern
# im ungesperrten Teil do_release_bauen_und_veroeffentlichen — die Selbstkontrolle ist mit
# umgezogen und muss weiterhin unmittelbar hinter `mvn clean deploy` stehen.
pruefe "der Release-Pfad ruft die Selbstkontrolle nach mvn clean deploy" "ja" \
       "$(sed -n '/^do_release_bauen_und_veroeffentlichen() {/,/^}/p' "$TUI" | grep -A6 'mvn clean deploy' | grep -q 'release_vollstaendig_pruefen "${NEW_VERSION}"' && echo ja || echo nein)"
pruefe "release_vollstaendig_pruefen: kein fataler Ausstieg" "0" \
       "$(sed -n '/^release_vollstaendig_pruefen() {/,/^}/p' "$TUI" | grep -v '^\s*#' | grep -cE 'return [1-9]|exit ' || true)"

echo "== Syntax (bash 3.2 = macOS /bin/bash, ueber den build-Wrapper) ============"
for f in "$LIB" "$SKRIPT" "$TUI"; do
    pruefe "bash -n $(basename "$f")" "ja" "$(bash -n "$f" 2>/dev/null && echo ja || echo nein)"
    [ -x /bin/bash ] && pruefe "/bin/bash -n $(basename "$f")" "ja" "$(/bin/bash -n "$f" 2>/dev/null && echo ja || echo nein)"
done

echo
if [ "$FEHLER" = "0" ]; then echo "ERGEBNIS: alle Faelle wie erwartet"; else echo "ERGEBNIS: FEHLER"; fi
exit "$FEHLER"
