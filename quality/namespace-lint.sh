#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  namespace-lint — Leitplanke gegen den alten Namespace `daniel-marthaler`
#
#  WARUM (Karte 600/606/642): Bis zum 10.08.2026 zog die zentrale CI ihre Build-Config
#  aus `daniel-marthaler/plaintext-config`, und fuenf POMs holten Java-Artefakte aus
#  `daniel-marthaler/plaintext-mvn`. Beides funktionierte — ueber den Transfer-Redirect,
#  den GitHub nach einem Repo-Umzug haelt. Ein Redirect ist aber eine Bequemlichkeit,
#  keine Zusage: er faellt weg, sobald unter dem alten Namen wieder ein Repo entsteht.
#  Dann liefert ein FREMDES Repository Build-Config, Skripte und Maven-Artefakte.
#
#  WAS DIE LUECKE IST: GitHubs Org-Actions-Allowlist greift nur fuer `uses:`-Referenzen.
#  Fuer `actions/checkout` mit `repository:`-Parameter, fuer Maven-Repository-URLs und
#  fuer `git clone` in Build-Skripten bietet GitHub KEINE Schranke — die muss selbstgebaut
#  sein. Genau das ist dieses Skript.
#
#  GEPRUEFT WIRD NUR, WAS FUNKTIONAL WIRKT: Workflows, POMs, renovate.json, build-Skripte.
#  Doku bleibt bewusst aussen vor: dort stehen historische Erklaerungen des Umzugs, und ein
#  Lint, der die anmeckert, wird abgeschaltet statt befolgt.
#
#  Aufruf:  quality/namespace-lint.sh [wurzelverzeichnis]     (Default: .)
#  Rueckgabe: 0 sauber, 1 Verstoss (oder kaputter Selbsttest).
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

MUSTER='daniel-marthaler'

# ── Dateien, die funktional wirken ────────────────────────────────────────────
dateien_finden() {
    local wurzel="$1"
    find "$wurzel" \
        \( -name .git -o -name target -o -name node_modules \) -prune -o \
        -type f \( \
            -path '*/.github/workflows/*.yaml' -o \
            -path '*/.github/workflows/*.yml' -o \
            -name 'pom.xml' -o \
            -name 'renovate.json' -o \
            -name 'build' -o \
            -name 'build.sh' \
        \) -print 2>/dev/null | sort
}

# ── Der eigentliche Check ─────────────────────────────────────────────────────
# Druckt Verstoesse als datei:zeile:inhalt. Rueckgabe 1, sobald einer dabei ist.
#
# Zwei Ausnahmen, beide begruendet:
#  1) <username>daniel-marthaler</username> — das ist das AUTH-Feld der settings.xml gegen
#     GitHub Packages (neben dem PAT aus secrets.MVN_DEPLOY_TOKEN), kein Namespace. Dort ist
#     kein Sicherheitsgewinn zu holen, ein kaputter Deploy-Login aber sehr wohl.
#  2) reine Kommentarzeilen — z. B. plaintext-schuetu/.github/workflows/ci-cd.yaml:90 ERKLAERT
#     die alte Referenz historisch. Ein Kommentar wird nicht ausgefuehrt. Eine Zeile mit
#     funktionalem Inhalt und angehaengtem Kommentar bleibt dagegen ein Verstoss.
treffer_suchen() {
    local wurzel="$1" gefunden=0 datei rohzeile nr inhalt
    while IFS= read -r datei; do
        [ -n "$datei" ] || continue
        while IFS= read -r rohzeile; do
            nr="${rohzeile%%:*}"
            inhalt="${rohzeile#*:}"
            printf '%s' "$inhalt" | grep -qE '<username>[[:space:]]*daniel-marthaler[[:space:]]*</username>' && continue
            printf '%s' "$inhalt" | grep -qE '^[[:space:]]*(#|<!--|//)' && continue
            printf '%s:%s:%s\n' "${datei#"$wurzel"/}" "$nr" "$inhalt"
            gefunden=1
        done < <(grep -nF "$MUSTER" "$datei" 2>/dev/null)
    done < <(dateien_finden "$wurzel")
    return $gefunden
}

# ── Selbsttest: der Check muss in BEIDE Richtungen belegt sein ────────────────
# Ohne ihn kann ein kaputtes find/grep (falscher Pfad, falsches Muster, leeres Verzeichnis)
# NICHTS finden und "gruen" melden — der Fehler saehe aus wie ein sauberes Repo. Genau
# dieser Fehlerklasse verdankt die Leitplanke ihre Existenz (das Dashboard aus Karte 606
# meldete zwei Wochen lang "success" und mass dabei den falschen Account).
# Zweite Richtung: die beiden bewussten Ausnahmen duerfen NICHT anschlagen, sonst faerbt
# der Lint bestehende, richtige Zustaende rot und wird binnen einer Woche entfernt.
selbsttest() {
    local t ausgabe rc anzahl
    t="$(mktemp -d)" || return 1
    mkdir -p "$t/.github/workflows" "$t/modul"

    # Muss ROT werden — je ein Verstoss in jedem geprueften Dateityp:
    printf '      repository: daniel-marthaler/plaintext-config\n'                        > "$t/.github/workflows/ci.yaml"
    printf '<url>https://maven.pkg.github.com/daniel-marthaler/plaintext-mvn</url>\n'      > "$t/modul/pom.xml"
    printf '{"registryUrls":["https://maven.pkg.github.com/daniel-marthaler/plaintext-mvn"]}\n' > "$t/renovate.json"
    printf 'git clone git@github.com:daniel-marthaler/plaintext-scripts.git\n'            > "$t/build"
    # Muss GRUEN bleiben — die beiden bewussten Ausnahmen:
    printf '                <username>daniel-marthaler</username>\n'                      > "$t/.github/workflows/auth.yaml"
    printf '    # Die alte Referenz "daniel-marthaler/plaintext-scripts" ist nur ein Redirect.\n' > "$t/.github/workflows/kommentar.yml"

    ausgabe="$(treffer_suchen "$t")"
    rc=$?
    rm -rf "$t"

    if [ "$rc" -ne 1 ]; then
        echo "::error::Selbsttest fehlgeschlagen — der Check findet die Verstoesse NICHT. Er ist wirkungslos, nicht das Repo sauber."
        return 1
    fi
    anzahl="$(printf '%s\n' "$ausgabe" | grep -c .)"
    if [ "$anzahl" -ne 4 ]; then
        echo "::error::Selbsttest fehlgeschlagen — erwartet 4 Verstoesse, gefunden $anzahl:"
        printf '%s\n' "$ausgabe"
        return 1
    fi
    if printf '%s\n' "$ausgabe" | grep -qE 'auth\.yaml|kommentar\.yml'; then
        echo "::error::Selbsttest fehlgeschlagen — eine bewusste Ausnahme (Auth-Feld / Kommentar) wurde als Verstoss gemeldet:"
        printf '%s\n' "$ausgabe"
        return 1
    fi
    echo "Selbsttest bestanden: 4/4 Verstoesse gefunden, beide Ausnahmen sauber durchgelassen."
    return 0
}

# ── Lauf ──────────────────────────────────────────────────────────────────────
WURZEL="${1:-.}"
if [ ! -d "$WURZEL" ]; then
    echo "::error::Verzeichnis '$WURZEL' existiert nicht — der Lint haette sonst ein leeres Verzeichnis gruen gemeldet."
    exit 1
fi

selbsttest || exit 1

echo "Geprueft werden: .github/workflows/*.y*ml, pom.xml, renovate.json, build, build.sh unter '$WURZEL'"
AUSGABE="$(treffer_suchen "$WURZEL")"
RC=$?
if [ "$RC" -ne 0 ]; then
    printf '%s\n' "$AUSGABE"
    echo "::error::Alter Namespace 'daniel-marthaler' in einer funktionalen Referenz. Das haelt heute nur der GitHub-Transfer-Redirect zusammen — er faellt weg, sobald der Name neu besetzt wird. Auf 'Plaintext-Gmbh/...' aendern."
    exit 1
fi
echo "Keine funktionale Referenz auf '$MUSTER' — sauber."
