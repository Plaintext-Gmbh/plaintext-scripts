#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  flyway-dubletten-lint — Leitplanke gegen zwei Migrationen mit derselben Versionsnummer
#
#  WARUM (Karte 1120/1121, 08.09.2026): In plaintext-guild trugen zwei Migrationen in
#  VERSCHIEDENEN Modulen dieselbe Nummer — `V1788709017__…` in `plaintext-guild-lists` und
#  in `plaintext-guild-portal`. Flyway legt alle Module in EINEN Versionsraum (es scannt
#  `classpath:db/migration` ueber den gesamten Klassenpfad) und bricht beim Kontextstart ab:
#
#      Error creating bean with name 'flywayInitializer' …
#      Found more than one migration with version 1788709017
#
#  Sichtbar wurde das als ROTER PLAYWRIGHT-SMOKE-LAUF — an einer Stelle also, die mit der
#  Ursache nichts zu tun hat. Wer nur "Playwright rot" liest, sucht zuerst in der Oberflaeche
#  und braucht dafuer Stunden. Diese Pruefung kostet Sekunden und laeuft VOR dem teuren Bau.
#
#  WARUM `./getflywaynr` das nicht faengt: Das Skript vergibt `date +%s` und vergleicht mit den
#  Migrationen im LOKALEN Arbeitsstand. Ein Klon, der aelter ist als origin/master, oder ein
#  zweiter Zweig, der gerade parallel dieselbe Sekunde erwischt hat, ist darin nicht sichtbar.
#  getflywaynr kann den Fall verkleinern (siehe dort), aber nicht ausschliessen — deshalb diese
#  zweite, unabhaengige Pruefung in der CI.
#
#  Aufruf:  quality/flyway-dubletten-lint.sh [wurzelverzeichnis] [--basis <ref>]
#  Rueckgabe: 0 sauber, 1 Dublette (oder kaputter Selbsttest).
#
#  --basis <ref>  Zusaetzlich die VORSCHAU AUF DEN MERGE pruefen: der Stand, der entstuende,
#                 wenn der aktuelle HEAD nach <ref> (i. d. R. origin/master) gemergt wuerde.
#                 Noetig ueberall dort, wo die CI den PR-HEAD auscheckt statt des Merge-Commits
#                 — bei Woodpecker ist CI_COMMIT_SHA genau der PR-Head. GitHub Actions checkt
#                 bei `pull_request` von sich aus refs/pull/N/merge aus; dort ist die Option
#                 ueberfluessig und wird weggelassen.
#                 Ohne die Vorschau bleibt genau der Fall unentdeckt, der Karte 1120 ausgeloest
#                 hat: zwei Zweige, jeder fuer sich sauber, erst zusammen kollidierend.
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

# Flyway-Fundort. Absichtlich der Pfadbestandteil und nicht nur der Dateiname: eine Datei
# `V1__x.sql` in einem Testressourcen-Ordner ist keine Migration, und die Dubletten-Meldung
# darueber waere ein Fehlalarm, der den Lint innerhalb einer Woche wieder abschaltet.
MIGRATIONS_PFAD='db/migration'

# ── Migrationsdateien einsammeln ──────────────────────────────────────────────
# Im Git-Klon ueber `git ls-files`: das zaehlt NUR versionierte Dateien und laesst damit
# Kopien in `target/` (die der Maven-Bau anlegt) und unversionierte Kladden aussen vor.
# Ohne Git faellt es auf `find` mit denselben Ausschluessen zurueck — das braucht der
# Selbsttest, und es macht das Skript ausserhalb der CI benutzbar.
dateien_finden() {
    local wurzel="$1"
    if git -C "$wurzel" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$wurzel" ls-files
    else
        # `find` liefert Pfade MIT Wurzelpraefix, `git ls-files` ohne — deshalb hier
        # abschneiden, damit beide Wege dieselbe Form haben.
        find "$wurzel" \( -name .git -o -name target -o -name node_modules \) -prune -o \
            -type f -print 2>/dev/null | sed "s#^${wurzel%/}/##"
    fi | grep -E "(^|/)${MIGRATIONS_PFAD}/V[^/]+__" | sort
    # Absichtlich immer 0: ohne Migrationen liefert `grep` eine 1, und unter `pipefail` wuerde
    # daraus am Aufrufer ein "Dublette gefunden" — ein Fehlalarm aus dem Nichts.
    return 0
}

# ── Versionsnummer aus dem Dateinamen ─────────────────────────────────────────
# Flyway liest alles zwischen dem fuehrenden `V` und dem doppelten Unterstrich als Version
# und deutet `_` darin als `.` — `V1_2__x.sql` und `V1.2__x.sql` sind dieselbe Version.
# NICHT nachgebildet ist Flyways numerischer Teilvergleich (`V1` == `V1.0`): hier sind alle
# Nummern Unix-Epochen ohne Punkt, und eine halbe Versionsarithmetik waere mehr Fehlerquelle
# als Gewinn. Wer je gemischte Schemata einfuehrt, muss hier nachziehen.
version_aus_pfad() {
    local basis
    basis="$(basename -- "$1")"
    basis="${basis#V}"
    basis="${basis%%__*}"
    printf '%s' "${basis//_/.}"
}

# ── Der eigentliche Check ─────────────────────────────────────────────────────
# Bekommt eine Liste von Dateipfaden auf stdin, druckt je doppelt vergebener Version einen
# Block mit den betroffenen Dateien. Rueckgabe 1, sobald eine Dublette dabei ist.
dubletten_melden() {
    local zeile version dublette gefunden=0
    local paare
    paare="$(while IFS= read -r zeile; do
        [ -n "$zeile" ] || continue
        version="$(version_aus_pfad "$zeile")"
        printf '%s\t%s\n' "$version" "$zeile"
    done | sort)"

    [ -n "$paare" ] || return 0

    while IFS= read -r dublette; do
        [ -n "$dublette" ] || continue
        gefunden=1
        echo "  Version $dublette ist doppelt vergeben:"
        printf '%s\n' "$paare" | awk -F'\t' -v v="$dublette" '$1 == v { print "    " $2 }'
    done < <(printf '%s\n' "$paare" | cut -f1 | uniq -d)

    return $gefunden
}

# ── Vorschau auf den Merge ────────────────────────────────────────────────────
# Liefert die Migrationsdateien, die NACH einem Merge von HEAD und <basis> vorhanden waeren.
#
# Die naive Variante — einfach beide Dateilisten aneinanderhaengen — erzeugt einen Fehlalarm,
# sobald ein Zweig eine noch nicht ausgerollte Migration UMBENENNT: die alte Datei steckt dann
# noch in <basis>, die neue schon im Zweig, beide mit derselben Nummer. Deshalb der Umweg ueber
# den merge-base: eine Datei, die in der gemeinsamen Basis stand und auf einer Seite fehlt,
# wurde dort geloescht und ueberlebt den Merge nicht.
merge_vorschau() {
    local wurzel="$1" basis="$2"
    local mb unsere ihre basis_dateien geloescht

    mb="$(git -C "$wurzel" merge-base HEAD "$basis" 2>/dev/null)" || return 2
    [ -n "$mb" ] || return 2

    unsere="$(dateien_finden "$wurzel")"
    ihre="$(git -C "$wurzel" ls-tree -r --name-only "$basis" \
        | grep -E "(^|/)${MIGRATIONS_PFAD}/V[^/]+__" | sort)"
    basis_dateien="$(git -C "$wurzel" ls-tree -r --name-only "$mb" \
        | grep -E "(^|/)${MIGRATIONS_PFAD}/V[^/]+__" | sort)"

    # Auf einer der beiden Seiten geloescht = in der gemeinsamen Basis vorhanden, dort nicht mehr.
    geloescht="$( { comm -23 <(printf '%s\n' "$basis_dateien") <(printf '%s\n' "$unsere");
                    comm -23 <(printf '%s\n' "$basis_dateien") <(printf '%s\n' "$ihre"); } | sort -u)"

    comm -23 <( { printf '%s\n' "$unsere"; printf '%s\n' "$ihre"; } | grep -v '^$' | sort -u) \
             <(printf '%s\n' "$geloescht" | grep -v '^$')
}

# ── Selbsttest: der Check muss in BEIDE Richtungen belegt sein ────────────────
# Ohne ihn kann ein kaputtes find/grep/sed NICHTS finden und "gruen" melden — der Fehler
# saehe aus wie ein sauberes Repo. Genau diese Falle ist der Grund, warum es diese Datei gibt:
# eine Lint-Regel, deren gruener Lauf nie gegen einen echten Fehlerfall gehalten wurde, belegt
# nichts. Deshalb wird HIER, in jedem einzelnen CI-Lauf, ein Duplikat kuenstlich erzeugt und
# nachgewiesen, dass die Regel darauf rot wird.
selbsttest() {
    local t rc ausgabe zeilen
    t="$(mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "rm -rf '$t'" RETURN

    # ── Richtung 1: Dublette ueber Modulgrenzen hinweg MUSS gefunden werden ──
    # Nachbau der Lage aus Karte 1120, Nummer und Modulnamen inklusive.
    mkdir -p "$t/rot/modul-lists/src/main/resources/db/migration" \
             "$t/rot/modul-portal/src/main/resources/db/migration" \
             "$t/rot/modul-lists/target/classes/db/migration"
    : > "$t/rot/modul-lists/src/main/resources/db/migration/V1788709017__listen_tabelle.sql"
    : > "$t/rot/modul-portal/src/main/resources/db/migration/V1788709017__portal_tabelle.sql"
    ausgabe="$(dateien_finden "$t/rot" | dubletten_melden)"
    rc=$?
    if [ "$rc" -ne 1 ]; then
        echo "::error::Selbsttest fehlgeschlagen — die Regel findet ein KUENSTLICH ANGELEGTES Duplikat NICHT (rc=$rc). Sie ist wirkungslos; ein gruener Lauf belegt dann nichts."
        return 1
    fi
    zeilen="$(printf '%s\n' "$ausgabe" | grep -c 'V1788709017__')"
    if [ "$zeilen" -ne 2 ]; then
        echo "::error::Selbsttest fehlgeschlagen — erwartet 2 gemeldete Dateien zur Dublette, gefunden $zeilen:"
        printf '%s\n' "$ausgabe"
        return 1
    fi

    # ── Richtung 2: ein sauberer Baum MUSS gruen bleiben ──
    # Sonst faerbt der Lint bestehende, richtige Zustaende rot und wird binnen einer Woche
    # wieder ausgebaut. Mit drin: die Faelle, die AUSSEHEN wie eine Dublette und keine sind —
    # eine Undo-Migration `U…` zur selben Nummer (anderer Migrationstyp, gehoert dazu), eine
    # wiederholbare Migration `R__` (hat gar keine Version) und eine gleichnamige Datei
    # ausserhalb von db/migration.
    mkdir -p "$t/gruen/modul-a/src/main/resources/db/migration" \
             "$t/gruen/modul-b/src/main/resources/db/migration" \
             "$t/gruen/modul-b/src/test/resources/testdaten"
    : > "$t/gruen/modul-a/src/main/resources/db/migration/V1788709017__eins.sql"
    : > "$t/gruen/modul-a/src/main/resources/db/migration/U1788709017__eins_zurueck.sql"
    : > "$t/gruen/modul-a/src/main/resources/db/migration/R__sichten.sql"
    : > "$t/gruen/modul-b/src/main/resources/db/migration/V1788709018__zwei.sql"
    : > "$t/gruen/modul-b/src/test/resources/testdaten/V1788709018__zwei.sql"
    ausgabe="$(dateien_finden "$t/gruen" | dubletten_melden)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "::error::Selbsttest fehlgeschlagen — ein SAUBERER Baum wird als Dublette gemeldet. Der Lint wuerde richtige Zustaende rot faerben:"
        printf '%s\n' "$ausgabe"
        return 1
    fi

    # ── Richtung 3: der Git-Weg muss dasselbe leisten wie der find-Weg ──
    # In der CI laeuft immer `git ls-files`; ein Selbsttest, der nur `find` prueft, liesse
    # genau den benutzten Pfad ungeprueft. Zugleich der Beleg, dass `target/` draussen bleibt:
    # die Kopie unter modul-lists/target ist nicht versioniert und darf keine dritte Meldung
    # erzeugen.
    cp -r "$t/rot" "$t/rot-git"
    git -C "$t/rot-git" init -q
    git -C "$t/rot-git" add -A >/dev/null 2>&1
    ausgabe="$(dateien_finden "$t/rot-git" | dubletten_melden)"
    rc=$?
    if [ "$rc" -ne 1 ]; then
        echo "::error::Selbsttest fehlgeschlagen — ueber 'git ls-files' wird das Duplikat NICHT gefunden (rc=$rc). Genau dieser Weg laeuft in der CI."
        return 1
    fi

    echo "Selbsttest bestanden: kuenstliches Duplikat wird ueber find UND git ls-files rot; sauberer Baum (U…, R__, Datei ausserhalb db/migration) bleibt gruen."
    return 0
}

# ── Lauf ──────────────────────────────────────────────────────────────────────
WURZEL='.'
BASIS=''
while [ $# -gt 0 ]; do
    case "$1" in
        --basis) BASIS="${2:-}"; shift 2 || true ;;
        --basis=*) BASIS="${1#--basis=}"; shift ;;
        -*) echo "::error::Unbekannte Option '$1'. Aufruf: $0 [wurzel] [--basis <ref>]"; exit 1 ;;
        *) WURZEL="$1"; shift ;;
    esac
done

if [ ! -d "$WURZEL" ]; then
    echo "::error::Verzeichnis '$WURZEL' existiert nicht — der Lint haette sonst ein leeres Verzeichnis gruen gemeldet."
    exit 1
fi

selbsttest || exit 1

ANZAHL="$(dateien_finden "$WURZEL" | grep -c . || true)"
echo "Geprueft: $ANZAHL Flyway-Migrationen unter '$WURZEL' (Pfadmuster */${MIGRATIONS_PFAD}/V*__*)."

# Kein einziger Fund ist verdaechtig genug, um es zu SAGEN, aber kein Fehler: nicht jedes Repo,
# das diese Pipeline benutzt, hat Migrationen (plaintext-fwtool zum Beispiel hat keine).
if [ "$ANZAHL" -eq 0 ]; then
    echo "Keine Migrationen in diesem Repo — nichts zu pruefen."
    exit 0
fi

FEHLER=0

BEFUND="$(dateien_finden "$WURZEL" | dubletten_melden)"
if [ $? -ne 0 ]; then
    echo "Doppelte Flyway-Versionsnummer im ausgecheckten Stand:"
    printf '%s\n' "$BEFUND"
    FEHLER=1
fi

if [ -n "$BASIS" ]; then
    if ! git -C "$WURZEL" rev-parse --verify --quiet "$BASIS" >/dev/null; then
        # HART ROT statt stiller Ueberspringer: wer --basis mitgibt, verlaesst sich darauf.
        # Ein "Ref nicht da, dann halt nicht" waere genau die Sorte gruener Lauf, die nichts
        # belegt (fehlendes `git fetch` im CI-Schritt sieht man sonst nie).
        echo "::error::Basis-Ref '$BASIS' ist im Klon nicht vorhanden. Vor dem Aufruf 'git fetch origin <branch>' ausfuehren — ohne den Ref waere die Merge-Vorschau lautlos ausgefallen."
        exit 1
    fi
    VORSCHAU="$(merge_vorschau "$WURZEL" "$BASIS")"
    if [ $? -eq 2 ]; then
        echo "::error::Kein gemeinsamer Vorfahr von HEAD und '$BASIS' — der Klon ist vermutlich flach (depth 1). Merge-Vorschau nicht moeglich."
        exit 1
    fi
    echo "Merge-Vorschau gegen '$BASIS': $(printf '%s\n' "$VORSCHAU" | grep -c . || true) Migrationen nach dem Merge."
    BEFUND="$(printf '%s\n' "$VORSCHAU" | dubletten_melden)"
    if [ $? -ne 0 ]; then
        echo "Doppelte Flyway-Versionsnummer NACH dem Merge nach '$BASIS' (im Zweig allein faellt sie nicht auf):"
        printf '%s\n' "$BEFUND"
        FEHLER=1
    fi
fi

if [ "$FEHLER" -ne 0 ]; then
    echo "::error::Zwei Migrationen mit derselben Flyway-Versionsnummer. Flyway legt ALLE Module in einen Versionsraum und bricht beim Kontextstart ab ('Found more than one migration with version …') — sichtbar wird das dann als roter Playwright-Lauf o. ae., also weit weg von der Ursache. Abhilfe: eine der beiden Dateien umbenennen, Nummer per './getflywaynr' neu ziehen."
    exit 1
fi

echo "Keine doppelte Flyway-Versionsnummer — sauber."
