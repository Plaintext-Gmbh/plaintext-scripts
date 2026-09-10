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
# Und auch die <release>-Angabe der metadata reicht nicht (Massnahme 4, 29.08.2026): sie steht,
# sobald der PARENT hochgeladen ist — die 24 Module folgen ueber rund 15 Minuten. Ein Bump in
# diesem Fenster sieht ein halbes Release. Deshalb gilt eine Version erst als veroeffentlicht,
# wenn JEDES Modul aus ihrem Parent-POM als <modul>-<version>.pom im Repo liegt
# (ci/reposilite-release.sh). Fehlt eines nachweislich (404), bumpt dieser Lauf nicht und sagt
# das (Exit 0, kein Fehler) — der naechste Lauf sieht das fertige Release. Antwortet das Repo
# dagegen gar nicht, ist das kein "fehlt", sondern "unbekannt": Exit 4 (Karte 1127).
#
# PORTABEL: laeuft auf den Linux-Runnern UND lokal auf macOS (BSD-Werkzeuge). Deshalb kein
# `sed -i` — GNU sed nimmt `-i` ohne Argument, BSD sed verlangt `-i ''`; die App-Kopien
# scheiterten lokal genau daran. Ersetzt wird ueber eine Tmp-Datei (ersetze_in_pom).
#
# Usage:
#   root-autobump.sh detect   -> schreibt current/parent/latest/behind nach stdout (+ GITHUB_OUTPUT)
#                                Exit 0 = nachgesehen (bump=true|false), 1 = harter Abbruch,
#                                4 = NICHT nachgesehen (Repo antwortet nicht). Siehe
#                                EXIT_NICHT_PRUEFBAR weiter unten.
#   root-autobump.sh apply    -> aendert pom.xml auf die neueste Version
# Umgebung: POM_FILE (Default pom.xml), ROOT_MAVEN_REPO (Default https://maven.plaintext.ch/releases),
#           BUMP_IGNORIERE_MODULE (Leerzeichen-getrennt: Module, die absichtlich nie deployt werden
#           und deshalb nicht auf die Vollstaendigkeit einzahlen; heute keines)
# ---------------------------------------------------------------------------
set -euo pipefail

POM="${POM_FILE:-pom.xml}"
REPO_BASE="${ROOT_MAVEN_REPO:-https://maven.plaintext.ch/releases}"
GROUP_PATH="ch/plaintext"

# Rueckgabecodes von `detect` (Karte 1127) — sie sind der einzige Unterschied zwischen
# "nachgesehen, nichts zu tun" und "konnte nicht nachsehen":
#
#   0  Die Frage ist BEANTWORTET. bump=true oder bump=false steht in der Ausgabe und in
#      $GITHUB_OUTPUT; auch "Release noch im Upload" faellt hierunter (kein Fehler, warten).
#   1  Harter Abbruch: die Antwort waere falsch (Property fehlt, Artefakt in root verschwunden,
#      unbekannter Modus). Muss jemand ansehen.
#   4  NICHT NACHGESEHEN: das Maven-Repo hat nicht geantwortet. Es ist KEINE Aussage ueber den
#      Rueckstand — weder "kein Bump" noch "Bump noetig".
#
# Bis zum 07.09.2026 endete "kein Bump noetig" ebenfalls mit 1, und der Workflow rief das
# Skript mit `|| true` auf. Damit sahen Ausfall und Ruhe fuer die Ampel gleich aus: als
# Twingate maven.plaintext.ch in den Tunnel zog, meldete der Lauf ueber Tage "kein
# Rueckstand" bei 9 Releases Rueckstand (Karte 988/1127, zuletzt real im Lauf 34195670774).
# Deshalb: kein `|| true` mehr im Workflow, und `detect` endet nur dann mit 0, wenn es die
# Quelle wirklich gelesen hat.
EXIT_NICHT_PRUEFBAR=4

die() { echo "::error::$*" >&2; exit 1; }

# Das Repo hat nicht geantwortet — es gibt keine Aussage, also auch keine gruene Ampel.
nicht_pruefbar() { echo "::error title=Auto-Bump konnte nicht nachsehen::$*" >&2; exit "$EXIT_NICHT_PRUEFBAR"; }

# Vollstaendigkeitspruefung (Massnahme 4) — dieselben Funktionen wie die Selbstkontrolle des
# Release-Jobs in tui-build-logic.sh. Liegt neben diesem Skript; ein App-Wrapper (README) zeigt
# per exec hierher, der Checkout im Workflow bringt beide Dateien mit.
# shellcheck source=ci/reposilite-release.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reposilite-release.sh"

# sed-Ersetzung in der pom ohne `-i` (BSD/GNU-Unterschied, siehe Kopf): Tmp-Datei + mv.
ersetze_in_pom() {   # $1 = sed-Ausdruck
  sed "$1" "$POM" > "$POM.tmp" && mv "$POM.tmp" "$POM"
}

# `| sed -n 1p` statt `| head -1` (Karte 1161): `head` steigt nach der ersten Zeile aus und
# schliesst seine Eingabe; der Schreiber links blockiert dann in `write()` und bekommt SIGPIPE,
# Rueckgabewert 141. Unter dem `set -euo pipefail` dieses Skripts bricht damit der ganze
# Auto-Bump ab, sobald die Datenmenge den Pipe-Puffer (64 KiB) uebersteigt. `sed -n 1p` liest bis
# EOF und liefert dieselbe erste Zeile. Die pom ist heute klein — die Bauform ist der Punkt,
# nicht die heutige Groesse; dieselbe Ursache hatte in den Testsuiten 15 von 20 Laeufen still
# falsch gruen gemeldet (Karte 1155).
#
# Aktuell gepinnte Version (Property in der Wurzel-pom).
current_pin() {
  grep -o '<plaintext-root\.version>[^<]*</plaintext-root\.version>' "$POM" \
    | sed -n 1p | sed 's/.*<plaintext-root\.version>//;s/<.*//'
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
    | sed -n 1p | sed 's/.*>//;s/<$//' || true
}

# Karte 1127: ein Netzfehler hier ist kein "kein Bump", sondern eine unbeantwortete Frage —
# darum EXIT_NICHT_PRUEFBAR statt die(). Der Code muss von jeder Ebene von Hand
# weitergereicht werden (`|| exit $?`), set -e allein genuegt nicht — Begruendung und Messung
# stehen bei latest_version.
fetch_metadata() {   # $1 = artifactId
  curl -sfL --max-time 30 "${REPO_BASE}/${GROUP_PATH}/$1/maven-metadata.xml" \
    || nicht_pruefbar "maven-metadata.xml fuer $1 nicht abrufbar (${REPO_BASE}) — Repo erreichbar?"
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

# Neueste Version laut <release> der Parent-Metadata. NUR die Nummer — ob das Release schon
# vollstaendig hochgeladen ist, sagt release_fehlend; ob es alles traegt, was DIESE pom braucht,
# sagt pruefe_benoetigte_artefakte. Die Reihenfolge der beiden ist Absicht (siehe detect).
latest_version() {
  local meta candidate
  # `|| exit $?` ist NICHT redundant neben `set -e` (gemessen 08.09.2026, bash 5.1): steht die
  # Zuweisung in einer Funktion, die ihrerseits per $(...) aufgerufen wird — genau die Kette
  # LATEST="$(latest_version)" -> meta="$(fetch_metadata …)" —, greift set -e nicht, und das
  # Skript lief nach dem ::error einfach weiter bis zum naechsten die() (Exit 1). Damit waere
  # der Ausfall wieder als gewoehnlicher Fehler verkleidet gewesen, statt als "nicht
  # nachgesehen" (Exit 4). Der Code wird deshalb an jeder Ebene von Hand weitergereicht.
  meta="$(fetch_metadata plaintext-root-parent)" || exit $?
  candidate="$(echo "$meta" | grep -o '<release>[^<]*</release>' | sed 's/.*<release>//;s/<.*//')"
  [ -n "$candidate" ] || die "kein <release> in der metadata von plaintext-root-parent"
  echo "$candidate"
}

# Massnahme 4: Welche Module des root-Release $1 fehlen noch im Repo? stdout: Liste
# (leer = vollstaendig); Rueckgabe wie reposilite_release_fehlend (0 vollstaendig, 1 unvollstaendig,
# 2 Parent-POM nicht abrufbar, 3 Parent-POM ohne Module). Ein unvollstaendiges Release ist KEIN
# Fehler dieses Skripts, sondern ein Zeitfenster — der Aufrufer wartet auf den naechsten Lauf.
release_fehlend() {
  reposilite_release_fehlend "$REPO_BASE" "$GROUP_PATH" plaintext-root-parent "$1" "${BUMP_IGNORIERE_MODULE:-}"
}

# Safety (seit Karte 361, kaputte Deploy-Pfade): die Version muss fuer JEDES Artefakt publiziert
# sein, an dem diese pom haengt. Laeuft NACH release_fehlend — dann ist das Release vollstaendig,
# und ein hier fehlendes Artefakt ist kein Zeitfenster mehr, sondern ein echtes Problem (Modul in
# root umbenannt oder entfernt): harter Abbruch, damit es jemand sieht.
pruefe_benoetigte_artefakte() {   # $1 = Version
  local a fehlend
  local -a benoetigt
  benoetigt=()
  while read -r a; do
    [ -n "$a" ] || continue
    benoetigt[${#benoetigt[@]}]="$a"
  done < <(required_artifacts)
  [ "${#benoetigt[@]}" -gt 0 ] || return 0
  fehlend="$(reposilite_fehlende_artefakte "$REPO_BASE" "$GROUP_PATH" "$1" "${benoetigt[@]}" | tr '\n' ' ')" || true
  [ -z "${fehlend% }" ] || case "$fehlend" in
    # Karte 1127: "(HTTP …)" heisst nicht pruefbar, nicht "fehlt". Ein Repo, das mitten in der
    # Pruefung wegbricht, darf nicht als "Modul in root entfernt" gemeldet werden — und schon
    # gar nicht stillschweigend zu einer gruenen Ampel fuehren.
    *'(HTTP '*) nicht_pruefbar "Artefakt-Pruefung fuer root-Release $1 nicht abschliessbar: ${fehlend% }" ;;
    *) die "root-Release $1 ist fuer Artefakt(e) ${fehlend% } NICHT publiziert, obwohl das Release vollstaendig ist — Bump abgebrochen (Modul in root umbenannt/entfernt?)" ;;
  esac
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
  # Kein $(...)-Zwischenschritt: fetch_metadata laeuft hier direkt in der Pipeline, ihr `exit 4`
  # beendet die Subshell von count_behind, und der Aufrufer reicht den Code per `|| exit $?`
  # weiter (siehe Kommentar in latest_version).
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
    LATEST="$(latest_version)" || exit $?
    BEHIND="$(count_behind "$CUR")" || exit $?
    BUMP=false
    if version_gt "$LATEST" "$CUR" || [ "$PAR" != "$LATEST" ]; then BUMP=true; fi

    # Massnahme 4: nur ein VOLLSTAENDIGES Release wird vorgeschlagen. Die Pruefung laeuft nur,
    # wenn ueberhaupt ein Bump anstuende — ein Repo auf dem neuesten Stand braucht keine 24 HEADs.
    FEHLEND=""; VOLL=0; UNPRUEFBAR=""
    if [ "$BUMP" = true ]; then
      FEHLEND="$(release_fehlend "$LATEST")" && VOLL=0 || VOLL=$?
      if [ "$VOLL" -ne 0 ]; then
        BUMP=false
        # Karte 1127 — die zweite Stelle, an der ein Ausfall wie Ruhe aussieht: auch hier wird
        # ueber HTTP gelesen, und "unvollstaendig" hiess bisher fuer JEDE Ursache "warten,
        # naechster Lauf" (Exit 0). Zwei Faelle sind aber keine Aussage:
        #   VOLL=2  Parent-POM nicht abrufbar. Das kann heissen "Upload gerade erst angelaufen"
        #           (404) ODER "Repo antwortet nicht" (000/5xx) — nur ein 404/410 ist eine
        #           Aussage. Deshalb genau EIN zusaetzlicher HEAD, der die beiden trennt.
        #   FEHLEND enthaelt "(HTTP …)"  Ein Modul war nicht pruefbar (reposilite_fehlende_-
        #           artefakte haengt den Code an). Es fehlt nicht — es ist unbekannt.
        if [ "$VOLL" -eq 2 ]; then
          PCODE_RC=0
          PCODE="$(reposilite_vorhanden "$(reposilite_pom_url "$REPO_BASE" "$GROUP_PATH" plaintext-root-parent "$LATEST")")" || PCODE_RC=$?
          [ "$PCODE_RC" -eq 1 ] \
            || UNPRUEFBAR="Parent-POM von ${LATEST} nicht lesbar (HTTP ${PCODE}) — kein 404, also keine Aussage ueber den Upload-Stand"
        fi
        case "$FEHLEND" in
          *'(HTTP '*) UNPRUEFBAR="Modulpruefung fuer ${LATEST} nicht abschliessbar: ${FEHLEND}" ;;
        esac
      else
        pruefe_benoetigte_artefakte "$LATEST"
      fi
    fi

    echo "current=${CUR} parent=${PAR} latest=${LATEST} behind=${BEHIND} vollstaendig=$([ "$VOLL" -eq 0 ] && echo ja || echo nein) bump=${BUMP}"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      {
        echo "current=${CUR}"
        echo "parent=${PAR}"
        echo "latest=${LATEST}"
        echo "behind=${BEHIND}"
        echo "vollstaendig=$([ "$VOLL" -eq 0 ] && echo true || echo false)"
        echo "fehlend=${FEHLEND}"
        echo "bump=${BUMP}"
        # Karte 1127: sagt dem Workflow (und der Zusammenfassung), ob ueberhaupt eine Antwort
        # vorliegt. Bei EXIT_NICHT_PRUEFBAR aus fetch_metadata wird dieser Block nie erreicht —
        # dann ist der Wert leer, und leer heisst ebenfalls "keine Antwort".
        echo "geprueft=$([ -z "$UNPRUEFBAR" ] && echo true || echo false)"
      } >> "$GITHUB_OUTPUT"
    fi

    # Erst melden, dann urteilen: die Ausgabe oben steht auch im Ausfall, damit die
    # Zusammenfassung des Laufs zeigt, wie weit man WAR, als die Quelle wegblieb.
    [ -z "$UNPRUEFBAR" ] || nicht_pruefbar "$UNPRUEFBAR"

    if [ "$VOLL" -ne 0 ]; then
      # Kein Fehler: das Release ist gerade im Upload (der Parent-POM fehlt mit 404, oder ein
      # Modul ist noch nicht da). Exit 0, damit der Lauf gruen bleibt und niemand einen
      # kaputten Bump vermutet. Steht dieselbe Meldung ueber Stunden, ist es kein Zeitfenster
      # mehr: dann fehlt ein Modul wirklich (Upload abgebrochen, maven.deploy.skip ->
      # BUMP_IGNORIERE_MODULE).
      echo "::notice title=Auto-Bump wartet::$(reposilite_fehlend_text "$VOLL" "$LATEST" "$FEHLEND"), naechster Lauf"
      exit 0
    fi

    # Karte 1127: frueher stand hier `[ "$BUMP" = true ]` — "kein Bump noetig" endete also mit
    # Exit 1, genau wie ein Netzfehler. Beide Faelle sind jetzt getrennt: wer bis hierher kommt,
    # HAT nachgesehen; ob gebumpt wird, steht in bump=. Der Workflow liest den Wert, nicht den
    # Rueckgabecode, und braucht deshalb kein `|| true` mehr.
    exit 0
    ;;
  apply)
    # Nicht "${2:-$(latest_version)}": in dieser Ersetzung ginge der Rueckgabecode des Abrufs
    # verloren (siehe Kommentar in latest_version).
    if [ -n "${2:-}" ]; then LATEST="$2"; else LATEST="$(latest_version)" || exit $?; fi
    version_gt "$LATEST" "$CUR" || [ "$PAR" != "$LATEST" ] \
      || die "kein Bump noetig (current=${CUR}, parent=${PAR}, latest=${LATEST})"
    version_gt "$CUR" "$LATEST" && die "Downgrade ${CUR} -> ${LATEST} verweigert"
    # Auch hier (Massnahme 4): apply mit einer Version, die noch nicht ganz da ist, ist ein
    # ausdruecklicher Auftrag, der nicht erfuellbar ist — anders als in detect deshalb ein Fehler.
    FEHLEND="$(release_fehlend "$LATEST")" && VOLL=0 || VOLL=$?
    [ "$VOLL" -eq 0 ] || die "$(reposilite_fehlend_text "$VOLL" "$LATEST" "$FEHLEND") — kein Bump"
    pruefe_benoetigte_artefakte "$LATEST"
    apply_pom "$CUR" "$LATEST"
    echo "pom.xml: plaintext-root ${CUR} -> ${LATEST} (parent ${PAR} -> ${LATEST})"
    ;;
  *)
    die "unbekannter Modus '${1}' (detect|apply)"
    ;;
esac
