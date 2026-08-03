#!/usr/bin/env bash
# =============================================================================
# pushover.sh — CI-Aufruf fuer Pushover-Meldungen.
# -----------------------------------------------------------------------------
# SEIT KARTE 382 NUR NOCH EIN DUENNER AUFSATZ auf ../pushover. Die Sende-, Prioritaets-
# und Fehlerlogik steht dort EINMAL, statt hier ein zweites Mal — das war der Zweck der
# Zusammenfuehrung. Diese Datei bleibt erhalten, weil die CI-Workflows sie unter diesem
# Pfad und mit dieser Argumentfolge aufrufen; ein Umbau der Workflows haette ohne Not
# alle Repositories beruehrt.
#
# Nutzung (unveraendert):
#   quality/pushover.sh "<Titel>" "<Nachricht>" [priority] [url] [url-title]
#
# Credentials weiterhin aus der Umgebung (GitHub-Secrets):
#   PUSHOVER_APP_TOKEN, PUSHOVER_USER_KEY
#
# Exit: 0 ok · 2 Parameter fehlt · 3 API-Fehler
# Fehlt die Konfiguration, wird NICHT hart abgebrochen (Exit 0 mit Warnung) — eine
# fehlende Benachrichtigung darf keinen CI-Job zum Scheitern bringen. Genau darin
# unterscheidet sich der CI-Aufruf vom direkten Werkzeug, das in dem Fall Exit 1 liefert.
# =============================================================================
set -uo pipefail

TITLE="${1:-}"
MESSAGE="${2:-}"
PRIORITY="${3:-0}"
URL="${4:-}"
URL_TITLE="${5:-Details}"

if [ -z "$TITLE" ] || [ -z "$MESSAGE" ]; then
  echo "Nutzung: $0 \"<Titel>\" \"<Nachricht>\" [priority] [url] [url-title]" >&2
  exit 2
fi

if [ -z "${PUSHOVER_APP_TOKEN:-}" ] || [ -z "${PUSHOVER_USER_KEY:-}" ]; then
  echo "WARNUNG: PUSHOVER_APP_TOKEN/PUSHOVER_USER_KEY nicht gesetzt — Benachrichtigung übersprungen." >&2
  exit 0
fi

WERKZEUG="${PUSHOVER_CMD:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pushover}"
if [ ! -x "$WERKZEUG" ]; then
  echo "WARNUNG: $WERKZEUG nicht gefunden — Benachrichtigung übersprungen." >&2
  exit 0
fi

ARGS=(-p "$PRIORITY" -t "$TITLE")
[ -n "$URL" ] && ARGS+=(-u "$URL" -U "$URL_TITLE")

if "$WERKZEUG" "${ARGS[@]}" "$MESSAGE"; then
  echo "Pushover: gesendet."
  exit 0
fi
exit 3
