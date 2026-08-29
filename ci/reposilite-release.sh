#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ci/reposilite-release.sh — Ist ein Multi-Modul-Release im Maven-Repo VOLLSTAENDIG?
#
# Massnahme 4 (Zustandsbericht 29.08.2026), "halbes Release sichtbar": `mvn deploy` von
# plaintext-root laedt 24 Module nacheinander hoch — den Parent zuerst, den Rest ueber rund
# 15 Minuten. Die maven-metadata.xml des Parents meldet die neue Version deshalb schon, wenn
# noch kein einziges Modul da ist. Wer in dieser Zeit die Version liest (Auto-Bump, ein Build
# gegen Reposilite), sieht ein halbes Release: einen Bump-PR, der nicht aufloesbar ist, oder
# einen roten Verify-Build mit einer Meldung, die die Ursache nicht nennt.
#
# `deployAtEnd=true` im root-POM war der erste Versuch und ist gescheitert: root deployt in
# ZWEI Repos (GitHub Packages + Reposilite); deployAtEnd fuehrte beide Ausfuehrungen am Ende
# noch einmal aus -> doppelter Upload -> 409 (zurueckgenommen). Also wird nicht der Upload
# umgebaut, sondern das LESEN: eine Version gilt erst als veroeffentlicht, wenn jedes Modul
# aus dem Parent-POM als <modul>-<version>.pom im Repo liegt.
#
# Sourced von: ci/root-autobump.sh (VOR dem Bump — fehlt ein Modul, wartet der Bump auf den
# naechsten Lauf) und tui-build-logic.sh (NACH mvn deploy — Selbstkontrolle des Release-Jobs).
# Reine Funktionen, keine Seiteneffekte beim Laden, braucht nur curl/grep/sed/awk. Laeuft
# unter bash 3.2 (macOS /bin/bash, ueber den build-Wrapper) wie unter bash 5 (Runner).
#
# ANNAHME: <module> im Parent-POM ist ein Verzeichnisname; hier wird er als artifactId gelesen.
# In plaintext-root sind beide gleich (24/24, geprueft 29.08.2026). Wer den Quellbaum hat
# (tui-build-logic.sh), bildet ueber <modul>/pom.xml auf die echte artifactId ab.
# ---------------------------------------------------------------------------

# Zeitbudget je HTTP-Aufruf (Sekunden). 24 Module x 20 s waeren im schlimmsten Fall 8 Minuten —
# real antwortet Reposilite im LAN in Millisekunden; der Wert faengt nur ein haengendes Netz.
: "${REPOSILITE_TIMEOUT:=20}"

# POM-URL eines Artefakts:  $1=Repo-Basis  $2=Group-Pfad (ch/plaintext)  $3=artifactId  $4=Version
reposilite_pom_url() { printf '%s/%s/%s/%s/%s-%s.pom\n' "$1" "$2" "$3" "$4" "$3" "$4"; }

# XML-Kommentare entfernen (auch mehrzeilige): ein auskommentiertes <module> ist kein Modul.
# stdin -> stdout. Ohne Verschachtelung, so wie XML sie auch nicht kennt.
reposilite_xml_ohne_kommentare() {
    awk '
        { zeile = $0; aus = ""
          while (length(zeile) > 0) {
              if (drin) {
                  i = index(zeile, "-->")
                  if (i == 0) { zeile = ""; break }
                  zeile = substr(zeile, i + 3); drin = 0
              } else {
                  i = index(zeile, "<!--")
                  if (i == 0) { aus = aus zeile; zeile = "" }
                  else { aus = aus substr(zeile, 1, i - 1); zeile = substr(zeile, i + 4); drin = 1 }
              }
          }
          print aus }'
}

# Liegt die Datei im Repo?  $1=URL.  stdout: der HTTP-Code (000 bei Netzfehler).
# Rueckgabe 0 = da (200), 1 = fehlt (404/410), 2 = nicht pruefbar (Netz, Auth, 5xx).
# HEAD statt GET: die Frage ist "gibt es die Datei", nicht "was steht drin".
# file://-URLs (Testbetrieb mit einem Repo im Dateisystem) beantwortet der Dateitest — curl
# liefert dort keinen HTTP-Code (%{http_code} = 000, Exit 37 bei fehlender Datei).
reposilite_vorhanden() {
    local code
    case "$1" in
        file://*) if [ -f "${1#file://}" ]; then echo 200; return 0; else echo 404; return 1; fi ;;
    esac
    # `|| true`: unter set -e (root-autobump.sh) wuerde ein Netzfehler sonst das Skript beenden,
    # bevor die Meldung "nicht pruefbar" entstehen kann. -w schreibt den Code auch dann.
    code="$(curl -s -o /dev/null -I -w '%{http_code}' --max-time "$REPOSILITE_TIMEOUT" "$1")" || true
    code="${code:-000}"
    echo "$code"
    case "$code" in
        200) return 0 ;;
        404|410) return 1 ;;
        *) return 2 ;;
    esac
}

# Modulliste eines Parent-POM im Repo:  $1=Repo-Basis  $2=Group-Pfad  $3=artifactId  $4=Version
# stdout: ein Modul je Zeile — nur die <modules> auf oberster Ebene. Module in <profiles>
# werden nicht mitgezaehlt: sie sind bedingt und im Release-Lauf typischerweise nicht aktiv;
# ein Warten auf sie wuerde nie enden.
# Rueckgabe 1, wenn das POM nicht abrufbar ist (Release gerade erst angelaufen, Repo weg).
reposilite_module_liste() {
    local url pom
    url="$(reposilite_pom_url "$@")"
    pom="$(curl -sfL --max-time "$REPOSILITE_TIMEOUT" "$url")" || return 1
    printf '%s\n' "$pom" | reposilite_xml_ohne_kommentare | awk '
        /<profiles>/  { profil = 1 }
        /<\/profiles>/ { profil = 0 }
        !profil && /<module>/ { m = $0; gsub(/.*<module>[[:space:]]*|[[:space:]]*<\/module>.*/, "", m); if (m != "") print m }'
}

# Fehlende Artefakte einer Version:  $1=Repo-Basis  $2=Group-Pfad  $3=Version, danach artifactIds.
# stdout: je Artefakt, das fehlt, eine Zeile "artifactId" — bzw. "artifactId (HTTP xxx)", wenn
# es nicht pruefbar war (5xx, Netz, Auth). Nicht pruefbar zaehlt wie fehlend: im Zweifel lieber
# nicht bumpen als einen unaufloesbaren Bump erzeugen.
# Rueckgabe 0 = alles da, 1 = mindestens eines fehlt oder ist nicht pruefbar.
reposilite_fehlende_artefakte() {
    local basis="$1" gruppe="$2" version="$3" a code rc fehlt=0
    shift 3
    for a in "$@"; do
        [ -n "$a" ] || continue
        code="$(reposilite_vorhanden "$(reposilite_pom_url "$basis" "$gruppe" "$a" "$version")")" && rc=0 || rc=$?
        case "$rc" in
            0) ;;
            1) echo "$a"; fehlt=1 ;;
            *) echo "$a (HTTP ${code:-000})"; fehlt=1 ;;
        esac
    done
    return "$fehlt"
}

# Gesamtpruefung: Parent-POM der Version lesen, jedes Modul pruefen.
#   $1=Repo-Basis  $2=Group-Pfad  $3=Parent-artifactId  $4=Version
#   [$5=zu ignorierende Module, Leerzeichen-getrennt — Module, die absichtlich nicht deployt
#        werden (maven.deploy.skip); ohne Ausnahme bliebe ein Release mit so einem Modul fuer
#        immer "unvollstaendig"]
# stdout: die fehlenden Module, Leerzeichen-getrennt (leer = vollstaendig).
# Rueckgabe: 0 vollstaendig, 1 unvollstaendig, 2 Parent-POM nicht abrufbar, 3 Parent-POM ohne <module>.
reposilite_release_fehlend() {
    local basis="$1" gruppe="$2" parent="$3" version="$4" ignorieren="${5:-}" module m fehlend
    local -a liste
    liste=()
    module="$(reposilite_module_liste "$basis" "$gruppe" "$parent" "$version")" || return 2
    [ -n "$module" ] || return 3
    while read -r m; do
        [ -n "$m" ] || continue
        case " $ignorieren " in *" $m "*) continue ;; esac
        liste[${#liste[@]}]="$m"
    done <<< "$module"
    # bash 3.2 + set -u: "${liste[@]}" auf einem leeren Array ist dort ein Fehler.
    [ "${#liste[@]}" -gt 0 ] || return 0
    fehlend="$(reposilite_fehlende_artefakte "$basis" "$gruppe" "$version" "${liste[@]}" | tr '\n' ' ')" || true
    fehlend="${fehlend% }"
    if [ -n "$fehlend" ]; then echo "$fehlend"; return 1; fi
    return 0
}

# Satz fuer Log und Meldung:  $1=Rueckgabe von reposilite_release_fehlend  $2=Version  $3=fehlende Module
reposilite_fehlend_text() {
    case "$1" in
        0) echo "Release $2 vollstaendig." ;;
        1) echo "Release $2 noch unvollstaendig (fehlt: $3)" ;;
        2) echo "Release $2: Parent-POM nicht abrufbar (Upload gerade erst angelaufen, oder Repo nicht erreichbar)" ;;
        3) echo "Release $2: Parent-POM traegt keine <module> — nichts zu pruefen, aber auch nichts bewiesen" ;;
        *) echo "Release $2: Vollstaendigkeit nicht ermittelbar (rc=$1)" ;;
    esac
}
