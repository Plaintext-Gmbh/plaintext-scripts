#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Karte 322 — Auto-Bump: root-Releases in ein Consumer-Repo ziehen.
#
# KANONISCHE FASSUNG (Zustandsbericht 29.08.2026, Paket S). Bis dahin lag dieses Skript
# byte-identisch in app, iot, schuetu und guild unter .github/scripts/root-autobump.sh —
# vier Kopien, die auseinanderlaufen, sobald eine korrigiert wird. Jetzt liegt es hier;
# der reusable Workflow .github/workflows/root-autobump.yaml ruft es aus dem Checkout von
# plaintext-scripts auf, und ein App-Repo haelt hoechstens einen duennen Wrapper (README,
# Abschnitt "root-autobump.sh"), der hierher zeigt.
#
# Ermittelt die neueste veroeffentlichte plaintext-root-Version und setzt sie in der
# pom.xml. Bewusst OHNE versions-maven-plugin: `versions:update-property` liefert hier
# falsche Ergebnisse, weil die Property ${plaintext-root.version} ueber ${plaintext.version}
# auch mit Artefakten verknuepft ist, die eine voellig andere Versionslinie haben (Messung
# 30.07.2026 in plaintext-iot: Vorschlag "1.422.0 -> 2.137.0", und `update-property` liess
# die Property gleichzeitig unveraendert).
#
# Versionsquelle ist die maven-metadata.xml des privaten NAS-Repos (maven.plaintext.ch,
# LAN-only, vom self-hosted Runner erreichbar) — also genau das Repo, aus dem der Build die
# Artefakte auch wirklich zieht. Ein Git-Tag im (oeffentlichen) plaintext-root reicht als
# Quelle NICHT: der Tag entsteht vor dem `mvn deploy`, ein Tag ohne publizierte Artefakte
# wuerde einen unaufloesbaren Bump erzeugen.
#
# PORTABEL: laeuft auf den Linux-Runnern UND lokal auf macOS (BSD-Werkzeuge). Deshalb kein
# `sed -i` — GNU sed nimmt `-i` ohne Argument, BSD sed verlangt `-i ''`; die App-Kopien
# scheiterten lokal genau daran. Ersetzt wird ueber eine Tmp-Datei (ersetze_in_pom).
#
# Usage:
#   root-autobump.sh detect   -> schreibt current/parent/latest/behind nach stdout (+ GITHUB_OUTPUT)
#   root-autobump.sh apply    -> aendert pom.xml auf die neueste Version
# Umgebung: POM_FILE (Default pom.xml), ROOT_MAVEN_REPO (Default https://maven.plaintext.ch/releases)
# ---------------------------------------------------------------------------
set -euo pipefail

POM="${POM_FILE:-pom.xml}"
REPO_BASE="${ROOT_MAVEN_REPO:-https://maven.plaintext.ch/releases}"
GROUP_PATH="ch/plaintext"

die() { echo "::error::$*" >&2; exit 1; }

# sed-Ersetzung in der pom ohne `-i` (BSD/GNU-Unterschied, siehe Kopf): Tmp-Datei + mv.
ersetze_in_pom() {   # $1 = sed-Ausdruck
  sed "$1" "$POM" > "$POM.tmp" && mv "$POM.tmp" "$POM"
}

# Aktuell gepinnte Version (Property in der Wurzel-pom).
current_pin() {
  grep -o '<plaintext-root\.version>[^<]*</plaintext-root\.version>' "$POM" \
    | head -1 | sed 's/.*<plaintext-root\.version>//;s/<.*//'
}

# Version im <parent>-Block (erster <version> nach <parent>).
current_parent() {
  awk '/<parent>/{p=1} p&&/<version>/{gsub(/.*<version>|<\/version>.*/,""); print; exit}' "$POM"
}

# Optionaler separater Interfaces-Pin. Liefert den ROHEN Wert — entweder eine Versionsnummer
# oder eine Property-Referenz wie ${plaintext-root.version}. Stand 29.08.2026: app und guild
# koppeln ueber genau diese Referenz, iot und schuetu haben keinen Interfaces-Pin.
# Die alte Fassung verglich den rohen Wert mit der Versionsnummer und meldete fuer
# "${plaintext-root.version}" jedes Mal "war schon vorher entkoppelt" — irrefuehrend, denn
# eine Referenz ist die engste Kopplung, die es gibt: sie folgt dem Bump von selbst.
current_interfaces() {
  grep -o '<plaintext-root-interfaces\.version>[^<]*<' "$POM" \
    | head -1 | sed 's/.*>//;s/<$//' || true
}

fetch_metadata() {   # $1 = artifactId
  curl -sfL --max-time 30 "${REPO_BASE}/${GROUP_PATH}/$1/maven-metadata.xml" \
    || die "maven-metadata.xml fuer $1 nicht abrufbar (${REPO_BASE}) — Repo erreichbar?"
}

# Alle root-Artefakte, die in dieser pom.xml an ${plaintext-root.version} bzw.
# ${plaintext-root-interfaces.version} haengen. Wird aus der pom abgeleitet, damit das Skript
# ohne Anpassung in jedem Consumer-Repo funktioniert.
required_artifacts() {
  {
    echo "plaintext-root-parent"
    awk '
      /<artifactId>/ { a=$0; gsub(/.*<artifactId>|<\/artifactId>.*/,"",a) }
      /\$\{plaintext-root(-interfaces)?\.version\}/ { if (a ~ /^plaintext-(root|admin)-/) print a }
    ' "$POM"
  } | sort -u
}

latest_version() {
  local meta candidate
  meta="$(fetch_metadata plaintext-root-parent)"
  candidate="$(echo "$meta" | grep -o '<release>[^<]*</release>' | sed 's/.*<release>//;s/<.*//')"
  [ -n "$candidate" ] || die "kein <release> in der metadata von plaintext-root-parent"

  # Safety: die Kandidatenversion muss fuer JEDES benoetigte Artefakt publiziert sein. Sonst
  # wuerde ein halb durchgelaufener root-Deploy (Karte 361: kaputte Deploy-Pfade) einen Bump
  # erzeugen, der gar nicht aufloesbar ist.
  local a
  while read -r a; do
    [ -n "$a" ] || continue
    if ! fetch_metadata "$a" | grep -q "<version>${candidate}</version>"; then
      die "root-Release ${candidate} ist fuer Artefakt '${a}' NICHT publiziert — Bump abgebrochen (unvollstaendiger root-Deploy?)"
    fi
  done < <(required_artifacts)

  echo "$candidate"
}

# 1.631.0 < 1.635.0 ; verhindert Downgrades bei zurueckgezogenen Releases.
# `sort -V` gibt es in GNU coreutils und im BSD sort von macOS (geprueft 29.08.2026).
version_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

# Karte 792 — wie viele root-Releases liegen zwischen dem Pin und heute?
# Quelle ist dieselbe maven-metadata.xml wie fuer latest_version; sie listet jede
# veroeffentlichte Version einzeln, nicht nur <release>. Der Wert dient allein der
# Sichtbarkeit: ein uebersprungener Lauf soll sagen koennen, WIE weit das Repo
# zurueckliegt — vorher meldete er nur "Bump noetig: nein/uebersprungen".
count_behind() {   # $1 = aktuell gepinnte Version
  fetch_metadata plaintext-root-parent \
    | grep -o '<version>[^<]*</version>' | sed 's/.*<version>//;s/<.*//' \
    | { n=0; while read -r v; do
          [ -n "$v" ] || continue
          version_gt "$v" "$1" && n=$((n + 1))
        done; echo "$n"; }
}

apply_pom() {   # $1 = alte root-version, $2 = neue
  local old="$1" new="$2" iface
  iface="$(current_interfaces)"

  # <parent><version> — nur der erste Treffer, im parent-Block.
  awk -v new="$2" '
    /<parent>/ { p=1 }
    p && /<version>/ && !done { sub(/<version>[^<]*<\/version>/, "<version>" new "</version>"); done=1 }
    /<\/parent>/ { p=0 }
    { print }
  ' "$POM" > "$POM.tmp" && mv "$POM.tmp" "$POM"

  ersetze_in_pom "s|<plaintext-root\.version>[^<]*</plaintext-root\.version>|<plaintext-root.version>${new}</plaintext-root.version>|"

  # Interfaces-Pin: drei Faelle, die sich fruehere Fassungen nicht auseinanderhielten.
  #   1. Referenz "${plaintext-root.version}" (app, guild): GEKOPPELT ueber die Property — der
  #      Bump oben wirkt automatisch, es gibt nichts zu ersetzen und nichts zu melden.
  #   2. Literal = alte Version: bisher synchron gehalten -> mitziehen.
  #   3. Literal != alte Version: bewusst entkoppelt (guild hatte das einmal so) -> NICHT
  #      stillschweigend hochziehen, nur melden.
  case "$iface" in
    '')
      ;;
    '${plaintext-root.version}')
      echo "plaintext-root-interfaces.version folgt ueber die Property \${plaintext-root.version} — gekoppelt, nichts zu tun."
      ;;
    "$old")
      ersetze_in_pom "s|<plaintext-root-interfaces\.version>[^<]*</plaintext-root-interfaces\.version>|<plaintext-root-interfaces.version>${new}</plaintext-root-interfaces.version>|"
      echo "plaintext-root-interfaces.version ${old} -> ${new} (war synchron, mitgezogen)."
      ;;
    *)
      echo "::notice::plaintext-root-interfaces.version (${iface}) ist bewusst entkoppelt von ${old} — bleibt unveraendert."
      ;;
  esac
}

CUR="$(current_pin)"
[ -n "$CUR" ] || die "<plaintext-root.version> in $POM nicht gefunden"
PAR="$(current_parent)"

case "${1:-detect}" in
  detect)
    LATEST="$(latest_version)"
    BEHIND="$(count_behind "$CUR")"
    echo "current=${CUR} parent=${PAR} latest=${LATEST} behind=${BEHIND}"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      {
        echo "current=${CUR}"
        echo "parent=${PAR}"
        echo "latest=${LATEST}"
        echo "behind=${BEHIND}"
        if version_gt "$LATEST" "$CUR" || [ "$PAR" != "$LATEST" ]; then
          echo "bump=true"
        else
          echo "bump=false"
        fi
      } >> "$GITHUB_OUTPUT"
    fi
    version_gt "$LATEST" "$CUR" || [ "$PAR" != "$LATEST" ]
    ;;
  apply)
    LATEST="${2:-$(latest_version)}"
    version_gt "$LATEST" "$CUR" || [ "$PAR" != "$LATEST" ] \
      || die "kein Bump noetig (current=${CUR}, parent=${PAR}, latest=${LATEST})"
    version_gt "$CUR" "$LATEST" && die "Downgrade ${CUR} -> ${LATEST} verweigert"
    apply_pom "$CUR" "$LATEST"
    echo "pom.xml: plaintext-root ${CUR} -> ${LATEST} (parent ${PAR} -> ${LATEST})"
    ;;
  *)
    die "unbekannter Modus '${1}' (detect|apply)"
    ;;
esac
