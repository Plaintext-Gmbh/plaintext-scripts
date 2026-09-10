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

# ── grep_q: `grep -q` unter `pipefail` ist eine Falle ─────────────────────────────────
# `grep -q` steigt beim ERSTEN Treffer aus und schliesst seine Eingabe. Der Schreiber links
# blockiert dann in `write()` und bekommt SIGPIPE, Rueckgabewert 141; `pipefail` reicht das als
# Pipeline-Fehler durch. Die Pipeline meldet "nicht gefunden", obwohl das Muster dasteht.
# Ausgeloest wird es, sobald der Schreiber nach dem Treffer noch schreiben will — also ab
# Pipe-Puffer-Groesse (64 KiB). Gemessen Karte 1161: bei 91 KB 17 von 20 Laeufen, bei 194 KB
# 0 von 20.
#
# DIE BEDINGUNG IST ENGER, ALS SIE KLINGT — gemessen am 10.09.2026, nicht abgeleitet.
# `grep` ist ZEILENorientiert: es kann erst aussteigen, wenn es eine VOLLSTAENDIGE Trefferzeile
# gelesen hat. Ausgeloest wird SIGPIPE deshalb nur, wenn nach der Trefferzeile noch mehr als ein
# Pipe-Puffer (64 KiB) folgt. Das trennt die drei Stellen hier scharf:
#
#   Zeile 107  `printf '%s\n' "$ausgabe" | grep_q -E 'auth\.yaml|kommentar\.yml'`
#              MEHRZEILIG, und der Treffer kann in Zeile 1 stehen — dahinter liegt dann die
#              ganze restliche Befundliste. Gemessen mit 529 KB und dem Treffer in Zeile 1:
#              `grep -q` 0 von 20 Laeufen, `grep_q` 20 von 20. Das ist der echte Defekt, und er
#              faellt auf die schlechte Seite: die Pruefung ist INVERTIERT gedacht (sie soll rot
#              werden, wenn eine bewusste Ausnahme faelschlich als Verstoss gemeldet wurde) und
#              meldete im Fehlerfall "nein, sauber". Der Selbsttest bestaetigte sich selbst.
#
#   Zeile 60/61  `printf '%s' "$inhalt" | grep_q -E …`
#              EINE EINZIGE Zeile OHNE Zeilenumbruch. `grep` muss sie bis EOF lesen, bevor es
#              ueberhaupt entscheiden kann, und steigt deshalb NIE vorzeitig aus. Gemessen mit
#              200 KB Zeilenlaenge, verankertes und unverankertes Muster, je 20 Laeufe: `grep -q`
#              20 von 20 richtig. Diese zwei Stellen waren also NICHT ausloesbar — Karte 1161
#              hat sie zu scharf eingeschaetzt. `grep_q` steht hier trotzdem: es ist wortgleich
#              in der Aussage, kostet nichts, und nimmt die Falle fuer den Naechsten weg, der
#              `$inhalt` einmal auf mehrere Zeilen umstellt.
#
# `grep_q` liest die Eingabe VOLLSTAENDIG (`grep -c`) und meldet denselben Rueckgabewert wie
# `grep -q`: 0 = mindestens ein Treffer, 1 = keiner. Optionen und Muster gehen unveraendert
# durch, die Aussage jeder Pruefung bleibt gleich — nur der Wettlauf ist weg. Wortgleich mit dem
# Helfer aus den Testsuiten (test-release-lock.sh u. a., Karte 1155, PR #113/f6ed1ef); bewusst
# derselbe Name und derselbe Rumpf, statt eine zweite Variante zu erfinden.
grep_q() { local n; n=$(grep -c "$@") || true; [ "${n:-0}" -gt 0 ]; }

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
            # grep_q statt grep -q: siehe Kopf. Hier VORSORGLICH — `$inhalt` ist eine einzelne
            # Zeile ohne Umbruch, `grep` steigt darauf nachweislich nie vorzeitig aus (200 KB,
            # 20 von 20 richtig). Die Aussage bleibt gleich; die Falle ist weg, falls `$inhalt`
            # je mehrzeilig wird.
            printf '%s' "$inhalt" | grep_q -E '<username>[[:space:]]*daniel-marthaler[[:space:]]*</username>' && continue
            printf '%s' "$inhalt" | grep_q -E '^[[:space:]]*(#|<!--|//)' && continue
            printf '%s:%s:%s\n' "${datei#"$wurzel"/}" "$nr" "$inhalt"
            gefunden=1
        # --binary-files=without-match: grep meldet bei Binaerdateien sonst "Binary file matches"
        # OHNE Zeilennummer — die Ausgabe waere dann nicht mehr datei:zeile:inhalt und der
        # Ausnahmen-Filter liefe ins Leere.
        done < <(grep -nF --binary-files=without-match "$MUSTER" "$datei" 2>/dev/null)
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
    # grep_q statt grep -q: siehe Kopf. DIES ist die Stelle, an der es wirklich kippte.
    # `$ausgabe` ist mehrzeilig und der Treffer kann in Zeile 1 stehen; dahinter liegt dann die
    # ganze restliche Befundliste. Gemessen mit 529 KB: `grep -q` 0 von 20, `grep_q` 20 von 20.
    # Die Pruefung ist INVERTIERT gedacht — sie soll rot werden, wenn eine bewusste Ausnahme
    # faelschlich als Verstoss gemeldet wurde. Mit `grep -q` fiel sie im Fehlerfall auf
    # "nein, sauber": der Selbsttest bestaetigte sich selbst.
    if printf '%s\n' "$ausgabe" | grep_q -E 'auth\.yaml|kommentar\.yml'; then
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
