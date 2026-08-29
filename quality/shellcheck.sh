#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  Lint der Bash-Skripte: bash -n + shellcheck (Zustandsbericht 29.08.2026, Paket S)
#
#  WARUM: plaintext-scripts ist die Build-Bibliothek ALLER Plaintext-Apps; ein Tippfehler in
#  tui-build-logic.sh bricht den naechsten Release in vier Repos gleichzeitig. Bis heute gab es
#  dafuer keine automatische Pruefung — nur die Testskripte fuer einzelne Funktionen.
#
#  WAS GEPRUEFT WIRD: jede Datei mit Bash-Shebang (#!/bin/bash, #!/usr/bin/env bash) — also
#  auch die ohne .sh-Endung (getflywaynr, modules, pushover, voice, start-template ...).
#  Erkannt wird ueber den Shebang, nicht ueber den Namen, damit ein neues Skript nicht
#  vergessen geht. Ausgenommen: .git, target, node_modules.
#
#  ZWEI STUFEN: `bash -n` (Syntax) ist die Mindestpruefung und laeuft immer; shellcheck laeuft,
#  wenn es installiert ist (lokal: brew install shellcheck; ubuntu-latest hat es vorinstalliert).
#  Fehlt shellcheck lokal, ist das ein Hinweis, kein Fehler — in der CI ist es Pflicht
#  (SHELLCHECK_PFLICHT=1), sonst waere ein Runner-Image ohne shellcheck nicht von einem
#  sauberen Repo zu unterscheiden.
#
#  SCHWEREGRAD: das Gate greift bei error + warning (-S warning). Die Stil-/Info-Hinweise
#  darunter (Stand 29.08.2026: 135 Stueck — 56x SC2029 "expands on the client side" an
#  ssh-Aufrufen, bei denen die Expansion auf dem Client ABSICHT ist; 25x SC2086 Quoting von
#  bewusst wortzerlegten Maven-Flags wie ${TEST_FLAG}; 18x SC2059 printf mit Farbcodes im
#  Format) sind keine Fehler. Sie alle in einem Zug "zu beheben" hiesse, Semantik zu aendern,
#  die niemand nachtestet — und ein Lint, der 135 Altlasten rot faerbt, wird abgeschaltet
#  statt befolgt. Was shellcheck als warning/error einstuft, MUSS sauber sein oder im Skript
#  mit begruendetem `# shellcheck disable=SCxxxx  # Grund` markiert werden.
#  (-S auf der Kommandozeile, nicht in einer .shellcheckrc: die kennt den Schluessel
#  `severity` nicht — am 29.08.2026 ausprobiert, die Notes kamen trotzdem.)
#
#  Aufruf:  quality/shellcheck.sh [wurzelverzeichnis]     (Default: Repo-Wurzel)
#  Rueckgabe: 0 sauber, 1 Befund.
# ═══════════════════════════════════════════════════════════════
set -uo pipefail

WURZEL="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
if [ ! -d "$WURZEL" ]; then
    echo "::error::Verzeichnis '$WURZEL' existiert nicht — ein leeres Verzeichnis waere sonst gruen."
    exit 1
fi
cd "$WURZEL" || exit 1

# Dateien mit Bash-Shebang sammeln (NUL-getrennt: Pfade koennten Leerzeichen tragen).
DATEIEN=()
while IFS= read -r -d '' f; do
    case "$(head -n 1 "$f" 2>/dev/null)" in
        '#!/bin/bash'*|'#!/usr/bin/env bash'*) DATEIEN+=("$f") ;;
    esac
done < <(find . \( -name .git -o -name target -o -name node_modules \) -prune -o -type f -print0 2>/dev/null)

if [ "${#DATEIEN[@]}" -eq 0 ]; then
    echo "::error::Keine Bash-Skripte unter '$WURZEL' gefunden — das waere ein leeres Repo oder ein kaputtes find."
    exit 1
fi
echo "Geprueft werden ${#DATEIEN[@]} Bash-Skripte unter '$WURZEL':"
printf '  %s\n' "${DATEIEN[@]}"

RC=0
# ── Stufe 1: Syntax ───────────────────────────────────────────────────────────
for f in "${DATEIEN[@]}"; do
    if ! bash -n "$f"; then
        echo "::error file=${f#./}::bash -n meldet einen Syntaxfehler"
        RC=1
    fi
done
if [ "$RC" -eq 0 ]; then
    echo "bash -n: alle ${#DATEIEN[@]} Dateien syntaktisch sauber."
else
    echo "bash -n: Syntaxfehler (siehe oben)."
fi

# ── Stufe 2: shellcheck ───────────────────────────────────────────────────────
if ! command -v shellcheck >/dev/null 2>&1; then
    if [ "${SHELLCHECK_PFLICHT:-0}" = "1" ]; then
        echo "::error::shellcheck ist nicht installiert, in der CI aber Pflicht (SHELLCHECK_PFLICHT=1)."
        exit 1
    fi
    echo "::warning::shellcheck nicht installiert — nur bash -n gelaufen (brew install shellcheck)."
    exit "$RC"
fi
echo "shellcheck $(shellcheck --version | sed -n 's/^version: //p') — Gate: -S warning"
# -f gcc: eine Zeile je Befund als datei:zeile:spalte — im Actions-Log direkt anklickbar.
if ! shellcheck -S warning -f gcc "${DATEIEN[@]}"; then
    echo "::error::shellcheck meldet Befunde (Schwere >= warning). Beheben oder im Skript mit begruendetem '# shellcheck disable=SCxxxx  # Grund' markieren."
    RC=1
else
    echo "shellcheck: keine Befunde."
fi
exit "$RC"
