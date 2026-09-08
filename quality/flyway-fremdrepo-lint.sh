#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  flyway-fremdrepo-lint — dieselbe Frage wie flyway-dubletten-lint.sh, aber ueber REPO-Grenzen
#
#  WARUM (Karte 1128, Restluecke 1 aus Karte 1121): Flyway scannt `classpath:db/migration` ueber
#  den GESAMTEN Klassenpfad. Der Klassenpfad einer laufenden Anwendung endet nicht am Repo:
#
#      plaintext-app     = app-Module          + plaintext-root-*  (Parent + Abhaengigkeiten)
#      plaintext-guild   = guild-Module        + plaintext-root-*  + acht plaintext-z-*-Module,
#                                                die im Repo plaintext-APP liegen
#      plaintext-schuetu = schuetu-Module      + plaintext-root-*
#      plaintext-iot     = iot-Module          + plaintext-root-*
#
#  Nachgemessen am 08.09.2026 ueber die artifactIds in den pom.xml der vier Repos: guild zieht
#  plaintext-app-interfaces, -z-auszahlungen, -z-countdown, -z-kalenderhost, -z-kontakte,
#  -z-mailbox, -z-postkonto, -z-rechnungen und -z-wiki aus dem app-Repo. app x guild ist also
#  KEIN theoretisches Paar, sondern eine echte Kante.
#
#  flyway-dubletten-lint.sh prueft nur das eigene Repo. Eine root-Migration und eine
#  app-Migration mit derselben Nummer sind dort BEIDE gruen — und brechen den Kontextstart der
#  laufenden Anwendung trotzdem ab:
#
#      Error creating bean with name 'flywayInitializer' …
#      Found more than one migration with version 1788709017
#
#  Am 08.09.2026 kollidiert nichts (alle zehn Paare mit `comm -12` verglichen, alle leer). Das
#  ist ein ZUSTAND, keine Absicherung: die Nummer ist `date +%s`, und zwei Repos brauchen nur
#  dieselbe Sekunde.
#
#  ── WARUM DIE NUMMERN LIVE GEHOLT WERDEN UND NICHT AUS EINER LISTE ────────────────────────
#  Verworfen wurden zwei naheliegendere Bauformen. Beide sind hier aufgeschrieben, weil sonst in
#  vier Wochen jemand dieselbe Frage noch einmal stellt:
#
#  (A) EIN ZENTRALER JOB, DER ALLE REPOS KLONT. Er haengt an keinem Pull Request und kann
#      deshalb nur MELDEN, was bereits gemergt ist — ein Monitor, keine Leitplanke. Genau das
#      Gegenteil dessen, was Karte 1121 erreicht hat (der Befund wandert VOR den teuren Bau).
#      Ausserdem: fuenf Klone fuer Daten, die je ein API-Aufruf liefert.
#
#  (B) EINE VEROEFFENTLICHTE NUMMERNLISTE, GEGEN DIE JEDES REPO PRUEFT. Sie ist per Konstruktion
#      veraltet: das Fenster zwischen "root mergt eine Migration" und "die Liste ist neu
#      veroeffentlicht" ist exakt das Fenster, in dem ein kollidierender app-PR gruen
#      durchlaeuft. Dazu ein Veroeffentlichungsschritt in fuenf Repos und ein Ablageort. Sie
#      hat also den Datenverzug von (A) UND zusaetzliche Infrastruktur.
#
#  Der Live-Abruf hat beides nicht: er laeuft IM Pull Request, vor dem Bau, und liest den Stand
#  von genau jetzt. Sein Preis ist eine Netzabhaengigkeit — die wird unten LAUT behandelt
#  (jeder Fehlschlag ist rot, nie ein stiller Uebersprung), inklusive `truncated` und
#  "null Migrationen zurueckbekommen".
#
#  ── BEWUSST GROB: JEDES REPO GEGEN JEDES ─────────────────────────────────────────────────
#  Der echte Graph ist enger als "alle gegen alle" (iot und guild teilen keinen Klassenpfad).
#  Trotzdem wird hier ohne Graph geprueft. Grund: die Nummern sind Unix-Epochen. Ein Treffer
#  zwischen zwei Repos, die einander nichts angehen, verlangt, dass zwei Menschen in derselben
#  SEKUNDE `./getflywaynr` ziehen — und die Abhilfe waere dieselbe wie bei einem echten Treffer
#  (eine der beiden Nummern neu ziehen, Kosten: eine Minute). Ein gepflegter
#  Abhaengigkeitsgraph waere dagegen eine zweite Wahrheit neben den pom.xml, die genau dann
#  falsch ist, wenn sie gebraucht wird.
#
#  Aufruf:
#      quality/flyway-fremdrepo-lint.sh <wurzel> --eigenes <owner/repo> [--pr <nr>]
#                                       [--familie "<owner/repo> …"] [--ohne-offene-prs]
#
#  Rueckgabe: 0 sauber (Warnungen aendern daran nichts), 1 Dublette gegen einen FREMDEN
#             master-Stand, oder kaputter Selbsttest, oder API-Fehlschlag.
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

# Die Familie. Wer ein Repo mit `db/migration` dazunimmt, traegt es HIER ein — und nur hier;
# alle fuenf Aufrufer erben die Liste. Ein Repo ohne Migrationen gehoert NICHT hinein: die
# Plausibilitaetspruefung unten wuerde es rot melden (siehe dort, das ist Absicht).
FAMILIE_VORGABE='Plaintext-Gmbh/plaintext-root
Plaintext-Gmbh/plaintext-app
Plaintext-Gmbh/plaintext-guild
Plaintext-Gmbh/plaintext-schuetu
Plaintext-Gmbh/plaintext-iot'

MIGRATIONS_PFAD='db/migration'
# Wortgleich mit flyway-dubletten-lint.sh: der PFADbestandteil, nicht nur der Dateiname. Eine
# Datei `V1__x.sql` unter src/test/resources/testdaten ist keine Migration.
MUSTER="(^|/)${MIGRATIONS_PFAD}/V[^/]+__"

# ── Versionsnummer aus dem Dateinamen ─────────────────────────────────────────
# Identisch zu flyway-dubletten-lint.sh, inklusive der Grenze: Flyways numerischer
# Teilvergleich (`V1` == `V1.0`) ist NICHT nachgebildet. Alle 302 Nummern der fuenf Repos sind
# reine Unix-Epochen ohne Punkt (nachgezaehlt 08.09.2026).
version_aus_pfad() {
    local basis
    basis="$(basename -- "$1")"
    basis="${basis#V}"
    basis="${basis%%__*}"
    printf '%s' "${basis//_/.}"
}

# stdin: Pfade. stdout: "nummer<TAB>pfad", sortiert. Nicht-Migrationen fallen raus.
#
# DER FILTER STEHT HIER UND NICHT NUR BEIM AUFRUFER. Beim ersten Anlauf filterte nur der
# Aufrufer, und der Selbsttest (Richtung 2) wurde prompt rot: er fuettert Pfade direkt und
# bekam `src/test/resources/testdaten/V…` als Migration gemeldet. Das ist genau der Fehlalarm,
# den der Pfadbestandteil `db/migration` verhindern soll — gefunden hat ihn die Gegenprobe,
# nicht das Lesen.
nummern_aus_pfaden() {
    local zeile
    grep -E "$MUSTER" | while IFS= read -r zeile; do
        [ -n "$zeile" ] || continue
        printf '%s\t%s\n' "$(version_aus_pfad "$zeile")" "$zeile"
    done | sort
    # `grep` liefert 1, wenn nichts passt — unter `pipefail` waere das am Aufrufer ein Fehler
    # aus dem Nichts.
    return 0
}

# ── Schnittmenge zweier Nummernlisten ─────────────────────────────────────────
# Argumente: zwei Dateien im Format "nummer<TAB>pfad". Druckt je gemeinsamer Nummer einen Block
# mit BEIDEN Fundorten. Rueckgabe 1, sobald es einen Treffer gibt.
#
# `comm -12` auf den reinen Nummernspalten — und danach die Pfade dazugesucht. Der naive Weg
# (beide Listen aneinanderhaengen und `uniq -d`) wuerde eine Nummer, die INNERHALB eines Repos
# doppelt vorkommt, faelschlich als repo-uebergreifenden Treffer melden. Diesen Fall hat
# flyway-dubletten-lint.sh, und die Meldung gehoert dorthin.
schnittmenge_melden() {
    local a="$1" b="$2" name_a="$3" name_b="$4"
    local treffer nummer gefunden=0

    treffer="$(comm -12 <(cut -f1 "$a" | sort -u) <(cut -f1 "$b" | sort -u))"
    [ -n "$treffer" ] || return 0

    while IFS= read -r nummer; do
        [ -n "$nummer" ] || continue
        gefunden=1
        echo "  Version $nummer liegt in BEIDEN Repos:"
        awk -F'\t' -v v="$nummer" -v r="$name_a" '$1 == v { print "    " r ": " $2 }' "$a"
        awk -F'\t' -v v="$nummer" -v r="$name_b" '$1 == v { print "    " r ": " $2 }' "$b"
    done <<< "$treffer"

    return $gefunden
}

# ── gh mit Wiederholung ───────────────────────────────────────────────────────
# Drei Versuche, weil ein einzelner Netzhaenger sonst einen ganzen CI-Lauf rot faerbt. Mehr als
# drei nicht: eine kaputte Berechtigung wird durch Warten nicht besser, und ein Lint, der zwei
# Minuten am Netz haengt, ist selbst ein Problem.
gh_mit_wiederholung() {
    local versuch ausgabe
    for versuch in 1 2 3; do
        if ausgabe="$(gh "$@" 2>&1)"; then
            printf '%s' "$ausgabe"
            return 0
        fi
        [ "$versuch" -lt 3 ] && sleep $((versuch * 3))
    done
    printf '%s' "$ausgabe" >&2
    return 1
}

# ── Migrationspfade eines fremden Repos vom Standardzweig ─────────────────────
# Ein einziger Aufruf je Repo (`git/trees?recursive=1`) statt eines Klons. Gemessen am
# 08.09.2026: app 2631 Dateien, root 1779, guild 654, schuetu 668, iot 203 — alle weit unter
# der Grenze der API (100 000 Eintraege / 7 MB), `truncated` ist bei allen false.
fremde_pfade() {
    local repo="$1" json trunkiert
    if ! json="$(gh_mit_wiederholung api "repos/${repo}/git/trees/HEAD?recursive=1")"; then
        echo "::error::Migrationsnummern von '${repo}' nicht lesbar (drei Versuche). Ohne diese Liste ist die repo-uebergreifende Pruefung wirkungslos — deshalb rot statt still uebersprungen. Haeufigste Ursache: der Token im Schritt hat kein Leserecht auf dieses (private) Repo. Meldung der API steht oben." >&2
        return 1
    fi
    # `truncated: true` heisst: die Dateiliste ist UNVOLLSTAENDIG. Eine unvollstaendige Liste
    # laesst genau die Migration weg, die kollidiert, und meldet gruen. Deshalb hart rot.
    trunkiert="$(printf '%s' "$json" | jq -r '.truncated')"
    if [ "$trunkiert" != "false" ]; then
        echo "::error::Die Dateiliste von '${repo}' kam GEKUERZT zurueck (truncated=${trunkiert}). Eine gekuerzte Liste kann die kollidierende Migration auslassen und waere gruen. Das Repo ist ueber die Baum-API nicht mehr in einem Stueck lesbar — hier muss auf einen flachen Klon umgestellt werden." >&2
        return 1
    fi
    printf '%s' "$json" | jq -r '.tree[].path' | grep -E "$MUSTER" | sort
    return 0
}

# ── Migrationspfade der offenen Pull Requests eines Repos ─────────────────────
# Eine GraphQL-Abfrage je Repo statt 1+N REST-Aufrufen. Gemessen am 08.09.2026: 28 offene PRs
# ueber die fuenf Repos, das waeren sonst 33 Aufrufe je Lint-Lauf.
#
# stdout: "prnummer<TAB>titel<TAB>pfad".
offene_pr_pfade() {
    local repo="$1" owner="${1%%/*}" name="${1##*/}" json
    if ! json="$(gh_mit_wiederholung api graphql -f owner="$owner" -f name="$name" -f query='
      query($owner:String!,$name:String!){
        repository(owner:$owner,name:$name){
          pullRequests(states:OPEN, first:100){
            nodes{ number title files(first:100){ pageInfo{hasNextPage} nodes{ path } } }
          }
        }
      }')"; then
        # ABSICHTLICH NUR EINE WARNUNG, kein Fehler: dieser Teil warnt ohnehin nur. Ein
        # Netzhaenger hier darf keinen PR rot faerben — aber er muss sichtbar sein, sonst ist
        # "keine Warnung" nicht von "nicht nachgesehen" zu unterscheiden.
        echo "::warning::Offene Pull Requests von '${repo}' nicht lesbar — die Vorwarnung auf parallele Zweige entfaellt fuer dieses Repo. Der blockierende Teil (gegen den master-Stand) ist davon nicht betroffen." >&2
        return 0
    fi
    # Eine gekuerzte Dateiliste eines EINZELNEN PR wird benannt. Ohne diese Zeile waere ein PR
    # mit ueber 100 geaenderten Dateien stillschweigend ungeprueft.
    printf '%s' "$json" \
      | jq -r '.data.repository.pullRequests.nodes[] | select(.files.pageInfo.hasNextPage) | "::warning::PR #\(.number) in '"$repo"' aendert mehr als 100 Dateien — seine Dateiliste ist gekuerzt, eine Migration darin bliebe unbemerkt."' >&2
    printf '%s' "$json" \
      | jq -r '.data.repository.pullRequests.nodes[] as $p | $p.files.nodes[] | "\($p.number)\t\($p.title)\t\(.path)"' \
      | grep -E "$MUSTER" | sort -u
    return 0
}

# ── Selbsttest ────────────────────────────────────────────────────────────────
# Derselbe Gedanke wie in flyway-dubletten-lint.sh: eine Regel, deren gruener Lauf nie gegen
# einen echten Fehlerfall gehalten wurde, belegt nichts. Geprueft wird die Vergleichslogik
# (Nummernauszug + Schnittmenge) offline in BEIDE Richtungen. Der API-Teil laesst sich hier
# nicht nachbilden; fuer ihn stehen die Plausibilitaetspruefungen oben (`truncated`, "null
# Migrationen", Fehlschlag = rot).
selbsttest() {
    local t rc ausgabe
    t="$(mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$t'" RETURN

    # ── Richtung 1: eine Nummer in ZWEI Repos muss gefunden werden ──
    # Nachbau des Falls, um den es geht: dieselbe Sekunde in root und in app.
    printf '%s\n' \
        'plaintext-root-common/src/main/resources/db/migration/V1788709017__root_tabelle.sql' \
        'plaintext-admin-cron/src/main/resources/db/migration/V1799000001__cron.sql' \
        | nummern_aus_pfaden > "$t/root.tsv"
    printf '%s\n' \
        'plaintext-z-wiki/src/main/resources/db/migration/V1788709017__wiki_tabelle.sql' \
        'plaintext-z-ocr/src/main/resources/db/migration/V1799000002__ocr.sql' \
        | nummern_aus_pfaden > "$t/app.tsv"

    ausgabe="$(schnittmenge_melden "$t/app.tsv" "$t/root.tsv" 'plaintext-app' 'plaintext-root')"
    rc=$?
    if [ "$rc" -ne 1 ]; then
        echo "::error::Selbsttest fehlgeschlagen — eine KUENSTLICH angelegte repo-uebergreifende Dublette wird NICHT gefunden (rc=$rc). Die Regel ist wirkungslos; ein gruener Lauf belegt dann nichts."
        return 1
    fi
    if [ "$(printf '%s\n' "$ausgabe" | grep -c 'V1788709017__')" -ne 2 ]; then
        echo "::error::Selbsttest fehlgeschlagen — erwartet BEIDE Fundorte in der Meldung, gefunden:"
        printf '%s\n' "$ausgabe"
        return 1
    fi

    # ── Richtung 2: saubere Staende muessen gruen bleiben ──
    # Mit drin sind die Faelle, die wie eine Dublette AUSSEHEN und keine sind: eine
    # Undo-Migration `U…` und eine wiederholbare `R__` zur selben Nummer, und eine gleichnamige
    # Datei ausserhalb von db/migration. Ohne diesen Teil faerbt der Lint richtige Zustaende rot
    # und wird binnen einer Woche wieder ausgebaut.
    printf '%s\n' \
        'plaintext-root-common/src/main/resources/db/migration/V1799000010__eins.sql' \
        'plaintext-root-common/src/main/resources/db/migration/U1799000020__eins_zurueck.sql' \
        'plaintext-root-common/src/main/resources/db/migration/R__sichten.sql' \
        | nummern_aus_pfaden > "$t/root2.tsv"
    printf '%s\n' \
        'plaintext-z-wiki/src/main/resources/db/migration/V1799000020__zwei.sql' \
        'plaintext-z-wiki/src/test/resources/testdaten/V1799000010__zwei.sql' \
        | nummern_aus_pfaden > "$t/app2.tsv"

    ausgabe="$(schnittmenge_melden "$t/app2.tsv" "$t/root2.tsv" 'plaintext-app' 'plaintext-root')"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "::error::Selbsttest fehlgeschlagen — zwei SAUBERE Staende werden als Dublette gemeldet (U…/R__/Datei ausserhalb db/migration nicht ausgenommen):"
        printf '%s\n' "$ausgabe"
        return 1
    fi

    # ── Richtung 3: eine repo-INTERNE Dublette darf hier NICHT gemeldet werden ──
    # Sie gehoert flyway-dubletten-lint.sh. Wuerde sie hier ebenfalls rot, stuende dieselbe
    # Sache doppelt im Log und der Fundort waere falsch benannt ("liegt in BEIDEN Repos").
    printf '%s\n' \
        'plaintext-guild-lists/src/main/resources/db/migration/V1788709017__a.sql' \
        'plaintext-guild-portal/src/main/resources/db/migration/V1788709017__b.sql' \
        | nummern_aus_pfaden > "$t/guild.tsv"
    printf '%s\n' \
        'plaintext-root-common/src/main/resources/db/migration/V1799000099__x.sql' \
        | nummern_aus_pfaden > "$t/root3.tsv"
    ausgabe="$(schnittmenge_melden "$t/guild.tsv" "$t/root3.tsv" 'plaintext-guild' 'plaintext-root')"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "::error::Selbsttest fehlgeschlagen — eine repo-INTERNE Dublette wird hier als repo-uebergreifende gemeldet. Sie gehoert in flyway-dubletten-lint.sh:"
        printf '%s\n' "$ausgabe"
        return 1
    fi

    echo "Selbsttest bestanden: eine kuenstliche Dublette ueber Repo-Grenzen wird mit BEIDEN Fundorten rot; saubere Staende (U…, R__, Datei ausserhalb db/migration) bleiben gruen; eine repo-INTERNE Dublette wird hier nicht mitgemeldet."
    return 0
}

# ── Lauf ──────────────────────────────────────────────────────────────────────
WURZEL='.'
EIGENES=''
PR_NUMMER=''
FAMILIE="$FAMILIE_VORGABE"
OFFENE_PRS=ja

while [ $# -gt 0 ]; do
    case "$1" in
        --eigenes)  EIGENES="${2:-}"; shift 2 || true ;;
        --eigenes=*) EIGENES="${1#--eigenes=}"; shift ;;
        --pr)       PR_NUMMER="${2:-}"; shift 2 || true ;;
        --pr=*)     PR_NUMMER="${1#--pr=}"; shift ;;
        --familie)  FAMILIE="${2:-}"; shift 2 || true ;;
        --familie=*) FAMILIE="${1#--familie=}"; shift ;;
        --ohne-offene-prs) OFFENE_PRS=nein; shift ;;
        -*) echo "::error::Unbekannte Option '$1'. Aufruf: $0 <wurzel> --eigenes <owner/repo> [--pr <nr>] [--familie \"<owner/repo> …\"] [--ohne-offene-prs]"; exit 1 ;;
        *) WURZEL="$1"; shift ;;
    esac
done

[ -d "$WURZEL" ] || { echo "::error::Verzeichnis '$WURZEL' existiert nicht — der Lint haette sonst ein leeres Verzeichnis gruen gemeldet."; exit 1; }
if [ -z "$EIGENES" ]; then
    echo "::error::--eigenes <owner/repo> fehlt. Ohne den eigenen Namen wuerde das Repo gegen SICH SELBST verglichen und jede eigene Migration als Dublette gemeldet."
    exit 1
fi
command -v gh >/dev/null 2>&1 || { echo "::error::'gh' ist nicht installiert. Die Nummern der Nachbarrepos werden ueber die GitHub-API geholt (siehe Kopf dieser Datei, Punkt A/B)."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "::error::'jq' ist nicht installiert."; exit 1; }

selbsttest || exit 1

ARBEIT="$(mktemp -d)" || exit 1
trap 'rm -rf "$ARBEIT"' EXIT

# ── Die eigenen Nummern ───────────────────────────────────────────────────────
# `git ls-files` und nicht `find`: das zaehlt nur versionierte Dateien und laesst die Kopien
# unter `target/` aussen vor. Auf GitHub steht hier bei `pull_request` der MERGE-Stand
# (actions/checkout holt ohne `ref:` refs/pull/N/merge) — also genau der Stand, der nach dem
# Merge gilt.
if ! git -C "$WURZEL" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "::error::'$WURZEL' ist kein Git-Arbeitsbaum. Der Lint braucht 'git ls-files', um Bau-Kopien unter target/ auszuschliessen."
    exit 1
fi
git -C "$WURZEL" ls-files | grep -E "$MUSTER" | sort | nummern_aus_pfaden > "$ARBEIT/eigen.tsv"
EIGEN_ANZAHL="$(grep -c . "$ARBEIT/eigen.tsv" || true)"
echo "Eigenes Repo ${EIGENES}: $EIGEN_ANZAHL Flyway-Migrationen im ausgecheckten Stand."

if [ "$EIGEN_ANZAHL" -eq 0 ]; then
    echo "Keine Migrationen in diesem Repo — nichts mit den Nachbarrepos zu vergleichen."
    exit 0
fi

FEHLER=0

# ── Teil 1 (BLOCKIEREND): gegen den master-Stand der Nachbarrepos ─────────────
# Blockierend, weil ein Treffer hier eine ECHTE, bereits bestehende Kollision ist: die fremde
# Migration liegt auf master, sie ist da. Mergen hiesse, den Kontextstart der Anwendung zu
# brechen. Die Abhilfe ist eine Minute Arbeit (eigene Nummer per './getflywaynr' neu ziehen).
for REPO in $FAMILIE; do
    [ "$REPO" = "$EIGENES" ] && continue

    if ! fremde_pfade "$REPO" > "$ARBEIT/fremd.pfade"; then
        FEHLER=1
        continue
    fi
    FREMD_ANZAHL="$(grep -c . "$ARBEIT/fremd.pfade" || true)"

    # PLAUSIBILITAET. Alle fuenf Repos der Familie haben Migrationen (root 69, app 155,
    # guild 47, schuetu 18, iot 13 — gezaehlt 08.09.2026). Kommen null zurueck, ist entweder
    # der Abruf schiefgegangen (leerer Baum bei fehlender Berechtigung) oder das Repo hat
    # wirklich keine Migrationen mehr; im zweiten Fall gehoert es aus FAMILIE_VORGABE
    # gestrichen. Beide Faelle brauchen eine Hand — ein stilles "0 Nummern, also kein
    # Treffer" waere der gruene Lauf, der nichts belegt.
    if [ "$FREMD_ANZAHL" -eq 0 ]; then
        echo "::error::Von '${REPO}' kamen NULL Migrationen zurueck. Alle Repos der Familie haben welche — entweder ist der Abruf fehlgeschlagen (Leserecht des Tokens pruefen) oder das Repo hat keine Migrationen mehr und gehoert aus FAMILIE_VORGABE in $(basename "$0") gestrichen."
        FEHLER=1
        continue
    fi

    nummern_aus_pfaden < "$ARBEIT/fremd.pfade" > "$ARBEIT/fremd.tsv"
    BEFUND="$(schnittmenge_melden "$ARBEIT/eigen.tsv" "$ARBEIT/fremd.tsv" "$EIGENES" "$REPO")"
    if [ $? -ne 0 ]; then
        echo "Dieselbe Flyway-Versionsnummer in ${EIGENES} und in ${REPO} (master):"
        printf '%s\n' "$BEFUND"
        FEHLER=1
    else
        echo "  ${REPO}: $FREMD_ANZAHL Migrationen, keine gemeinsame Nummer."
    fi
done

# ── Teil 2 (NUR WARNUNG): gegen die offenen Pull Requests der Familie ─────────
# Restluecke 2 aus Karte 1121: zwei gleichzeitig offene Zweige sehen einander nicht. Weder der
# Merge-Ref noch `--basis origin/master` kennen einen Zweig, der noch nicht gemergt ist.
#
# WARUM NUR EINE WARNUNG — und warum das nicht bloss Bequemlichkeit ist:
#   * Der Befund ist NICHT SELBSTVERSCHULDET. Wessen PR rot wird, entscheidet allein, wer
#     spaeter laeuft. Ein PR, der rot ist, weil jemand anders zeitgleich arbeitet, ist der
#     schnellste Weg, eine Regel unglaubwuerdig zu machen.
#   * Der Befund ist FLUECHTIG. Wird der andere PR geschlossen statt gemergt, war die Warnung
#     gegenstandslos — und ein blockierender Befund, den man durch Nichtstun aufloest, erzieht
#     zum Wegklicken.
#   * Er wird SPAETER OHNEHIN BLOCKIEREND. Sobald der andere Zweig auf master liegt, greift
#     Teil 1 bzw. flyway-dubletten-lint.sh. Es geht hier um Vorwarnzeit, nicht um die
#     Absicherung selbst — die steht woanders.
# Wer daraus ein `exit 1` macht, dreht die Beweislast um: dann blockiert nicht mehr die
# Kollision, sondern die Gleichzeitigkeit.
if [ "$OFFENE_PRS" = ja ]; then
    echo
    echo "Vorwarnung: offene Pull Requests der Familie (nur Hinweis, faerbt nichts rot)."
    WARNUNGEN=0
    for REPO in $FAMILIE; do
        offene_pr_pfade "$REPO" > "$ARBEIT/pr.roh" || continue
        [ -s "$ARBEIT/pr.roh" ] || continue

        while IFS=$'\t' read -r NR TITEL PFAD; do
            [ -n "$PFAD" ] || continue
            # Der eigene PR ist kein fremder Zweig. Ohne diese Zeile meldete jeder PR mit einer
            # Migration sich selbst.
            [ "$REPO" = "$EIGENES" ] && [ -n "$PR_NUMMER" ] && [ "$NR" = "$PR_NUMMER" ] && continue
            NUMMER="$(version_aus_pfad "$PFAD")"
            if cut -f1 "$ARBEIT/eigen.tsv" | grep -qx "$NUMMER"; then
                WARNUNGEN=$((WARNUNGEN + 1))
                echo "::warning::Flyway-Nummer $NUMMER wird auch im OFFENEN PR ${REPO}#${NR} vergeben (${PFAD} — \"${TITEL}\"). Beide Zweige sind fuer sich gruen; wer zuletzt mergt, faerbt rot. Wer zuerst mergt, gewinnt die Nummer — der andere zieht sie per './getflywaynr' neu."
            fi
        done < "$ARBEIT/pr.roh"
    done
    if [ "$WARNUNGEN" -eq 0 ]; then
        echo "  Kein offener Pull Request der Familie belegt eine der eigenen Nummern."
    fi
fi

if [ "$FEHLER" -ne 0 ]; then
    echo "::error::Dieselbe Flyway-Versionsnummer in zwei Repos, deren Module in EINEM Klassenpfad landen. Flyway scannt classpath:db/migration ueber den ganzen Klassenpfad und bricht beim Kontextstart ab ('Found more than one migration with version …') — sichtbar wird das dann weit weg von der Ursache, etwa als roter Playwright-Lauf. Abhilfe: die eigene Migration umbenennen, Nummer per './getflywaynr' neu ziehen."
    exit 1
fi

echo
echo "Keine Flyway-Nummer doppelt ueber Repo-Grenzen — sauber."
