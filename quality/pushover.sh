#!/usr/bin/env bash
# =============================================================================
# pushover.sh — Pushover-Benachrichtigung aus der CI (env-basiert)
# -----------------------------------------------------------------------------
# CI-taugliche Variante (Credentials aus Umgebungsvariablen, kein Config-File):
#   PUSHOVER_APP_TOKEN, PUSHOVER_USER_KEY  (als GitHub-Secrets gesetzt)
#
# Nutzung:
#   quality/pushover.sh "<Titel>" "<Nachricht>" [priority] [url] [url-title]
#     priority : -2..2 (Default 0; 1 = high/bypass quiet hours)
#     url      : optionaler Link (z.B. Dashboard/Sonar)
#
# Exit: 0 ok · 1 Config fehlt · 2 Parameter fehlt · 3 API-Fehler
# Fehlt die Config, wird NICHT hart abgebrochen (return 0 mit Warnung), damit ein
# fehlendes Secret keinen CI-Job killt — die Benachrichtigung ist Zusatz, nicht Gate.
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

ARGS=(--form-string "token=${PUSHOVER_APP_TOKEN}"
      --form-string "user=${PUSHOVER_USER_KEY}"
      --form-string "title=${TITLE}"
      --form-string "message=${MESSAGE}"
      --form-string "priority=${PRIORITY}")
if [ -n "$URL" ]; then
  ARGS+=(--form-string "url=${URL}" --form-string "url_title=${URL_TITLE}")
fi

RESPONSE=$(curl -s -X POST https://api.pushover.net/1/messages.json "${ARGS[@]}" --max-time 15)
if echo "$RESPONSE" | grep -q '"status":1'; then
  echo "Pushover: gesendet."
  exit 0
fi
echo "Pushover-Fehler: $RESPONSE" >&2
exit 3
