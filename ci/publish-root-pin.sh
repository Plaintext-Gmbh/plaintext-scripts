#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Karte 1145 — den root-Pin nach Plaintext-Gmbh/plaintext-mvn melden, aus WOODPECKER.
#
# WOZU (unveraendert gegenueber dem GitHub-Weg, Karte 942):
# Der Aufraeum-Workflow in plaintext-mvn duennt die publizierten Maven-Paketversionen aus.
# Damit er keine Version loescht, die eine App noch braucht, schiebt jede App ihren Pin
# selbst hinueber — die App-Repos sind privat, plaintext-mvn ist oeffentlich, ein Holen
# waere der falsche Weg herum.
#
# WARUM ES DIESE FASSUNG GIBT (09.09.2026):
# Der GitHub-Workflow lief mit AUTOBUMP_TOKEN, und das ist ein Token des Zweitkontos
# `Plaintext-User`. Dieses Konto ist von GitHub gesperrt worden ("Your account was
# suspended", HTTP 403 bei jedem Aufruf) — gemessen am 09.09.2026 an iot und guild, beide
# Pin-Laeufe rot. Damit faellt der ganze Weg aus, und zwar nicht wegen eines Fehlers im
# Ablauf, sondern weil das ausfuehrende Konto weg ist.
#
# Diese Fassung benutzt deshalb `mvn_deploy_token` — dasselbe Token, mit dem Woodpecker
# schon heute Release-Commits pusht und Bump-PRs eroeffnet, und das dem Hauptkonto gehoert.
# Es gibt kein zweites Konto mehr, an dem etwas haengen kann.
#
# UNTERSCHIED ZUM GITHUB-SKRIPT: kein `gh` und kein `jq` vorausgesetzt — Woodpecker-Images
# haben beides nicht zuverlaessig. Gesprochen wird direkt mit der REST-API (curl), die JSON-
# Auswertung macht Python 3, das in den benutzten Images vorhanden ist.
#
# AUFRUF (aus .woodpecker/pin.yml des jeweiligen App-Repos):
#   MVN_DEPLOY_TOKEN=<token> REPO_NAME=plaintext-iot COMMIT_SHA=<sha> \
#     bash <scripts-klon>/ci/publish-root-pin.sh
#
# Umgebung (mit Vorgaben):
#   MVN_REPO        Plaintext-Gmbh/plaintext-mvn
#   PIN_BRANCH      pins
#   HEARTBEAT_DAYS  7    — nach so vielen Tagen wird auch ohne Aenderung neu geschrieben,
#                          damit ein stehengebliebener Pin drueben als DEFEKT auffaellt
#                          (der Aufraeumer bricht bei einem Pin > 30 Tage ab).
# ---------------------------------------------------------------------------
set -euo pipefail

MVN_REPO="${MVN_REPO:-Plaintext-Gmbh/plaintext-mvn}"
PIN_BRANCH="${PIN_BRANCH:-pins}"
HEARTBEAT_DAYS="${HEARTBEAT_DAYS:-7}"
API="https://api.github.com"

: "${MVN_DEPLOY_TOKEN:?MVN_DEPLOY_TOKEN fehlt — ohne Schreibrecht auf ${MVN_REPO} kann der Pin nicht gemeldet werden}"
REPO_NAME="${REPO_NAME:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}"
COMMIT_SHA="${COMMIT_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unbekannt)}"
TARGET="pins/${REPO_NAME}.env"

# ── Welche root-Versionen benutzt dieses Repo? ────────────────────────────────
# Die <parent>-Version plus jede <plaintext-root*.version>-Property. Properties, die auf
# eine andere Property verweisen (${...}), fallen durch den Regex-Filter heraus — sie sind
# keine eigene Angabe. Bewusst generisch: plaintext-guild hatte den Interfaces-Pin schon
# einmal entkoppelt, und der naechste Sonderfall soll dieses Skript nicht brauchen.
PARENT="$(awk '/<parent>/{p=1} p&&/<version>/{gsub(/.*<version>|<\/version>.*/,""); print; exit}' pom.xml)"
PROPS="$(grep -o '<plaintext-root[a-z-]*\.version>[^<]*' pom.xml | sed 's/.*>//' || true)"
VERS="$(printf '%s\n%s\n' "$PARENT" "$PROPS" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -Vu | tr '\n' ' ')"
VERS="${VERS% }"

if [ -z "$VERS" ]; then
  echo "FEHLER: In der pom.xml steht keine aufloesbare root-Version (parent='${PARENT}')." >&2
  echo "FEHLER: Es wird NICHTS geschrieben — ein leerer Pin wuerde drueben als Freigabe zum Loeschen gelesen." >&2
  exit 1
fi
echo "gefunden: ${VERS}"

api() {  # api <methode> <pfad> [datei-mit-json]
  local m="$1" p="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -m 60 -X "$m" -H "Authorization: Bearer ${MVN_DEPLOY_TOKEN}" \
         -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
         --data-binary "@${body}" "${API}${p}"
  else
    curl -sS -m 60 -X "$m" -H "Authorization: Bearer ${MVN_DEPLOY_TOKEN}" \
         -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
         "${API}${p}"
  fi
}

# ── Aktuellen Stand drueben lesen ─────────────────────────────────────────────
RESP="$(api GET "/repos/${MVN_REPO}/contents/${TARGET}?ref=${PIN_BRANCH}" || true)"
read -r SHA OLD_VERS OLD_UPD <<EOF
$(printf '%s' "$RESP" | python3 -c '
import base64,json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(". . ."); raise SystemExit
sha=d.get("sha") or "."
alt=base64.b64decode(d.get("content") or "").decode("utf-8","replace")
vers=upd="."
for z in alt.splitlines():
    if z.startswith("versions="): vers=z.split("=",1)[1].strip() or "."
    if z.startswith("updated="):  upd=z.split("=",1)[1].strip() or "."
print(sha, vers, upd)')
EOF
[ "$SHA" = "." ] && SHA=""
[ "$OLD_VERS" = "." ] && OLD_VERS=""
[ "$OLD_UPD" = "." ] && OLD_UPD="1970-01-01T00:00:00Z"

OLD_TS="$(date -u -d "$OLD_UPD" +%s 2>/dev/null || echo 0)"
AGE_D=$(( ( $(date -u +%s) - OLD_TS ) / 86400 ))

if [ "$OLD_VERS" = "$VERS" ] && [ "$AGE_D" -lt "$HEARTBEAT_DAYS" ]; then
  echo "${TARGET} steht bereits auf '${VERS}' und ist ${AGE_D} Tage alt — nichts zu tun."
  exit 0
fi

GRUND="Pin geaendert (${OLD_VERS:-neu} -> ${VERS})"
[ "$OLD_VERS" = "$VERS" ] && GRUND="Heartbeat (${AGE_D} Tage seit dem letzten Schreiben)"

# ── Schreiben, mit Wiederholung ───────────────────────────────────────────────
# Die Contents-API arbeitet optimistisch ueber die Blob-SHA. Kollisionen sind unwahrschein-
# lich (jedes Repo schreibt seine EIGENE Datei), aber plaintext-mvn bekommt bei jedem
# root-Release einen Push — schlaegt der Aufruf fehl, wird die SHA neu gelesen und erneut
# versucht. Der Commit drueben traegt [skip ci]: plaintext-mvn soll dafuer nichts starten.
ok=false
for versuch in 1 2 3 4 5; do
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  RUMPF="$(mktemp)"
  printf 'repo=%s\nversions=%s\nupdated=%s\ncommit=%s\n' \
         "$REPO_NAME" "$VERS" "$NOW" "${COMMIT_SHA:0:9}" \
    | base64 -w0 \
    | REPO_NAME="$REPO_NAME" VERS="$VERS" PIN_BRANCH="$PIN_BRANCH" SHA="$SHA" python3 -c '
import json,os,sys
name = os.environ["REPO_NAME"]
vers = os.environ["VERS"]
d = {"branch": os.environ["PIN_BRANCH"],
     "message": "chore(pins): " + name + " benutzt " + vers + " [skip ci]",
     "content": sys.stdin.read().strip()}
if os.environ.get("SHA"):
    d["sha"] = os.environ["SHA"]
json.dump(d, sys.stdout)' > "$RUMPF"

  ANTWORT="$(api PUT "/repos/${MVN_REPO}/contents/${TARGET}" "$RUMPF" || true)"
  rm -f "$RUMPF"
  if printf '%s' "$ANTWORT" | grep -q '"content"'; then ok=true; break; fi

  echo "WARNUNG: Versuch ${versuch} fehlgeschlagen: $(printf '%s' "$ANTWORT" | head -c 300)" >&2
  sleep $(( versuch * 4 ))
  SHA="$(api GET "/repos/${MVN_REPO}/contents/${TARGET}?ref=${PIN_BRANCH}" \
         | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("sha",""))' 2>/dev/null || true)"
done

if [ "$ok" != true ]; then
  echo "FEHLER: ${TARGET} auf Branch ${PIN_BRANCH} von ${MVN_REPO} konnte nicht geschrieben werden." >&2
  echo "FEHLER: Der Aufraeum-Workflow drueben arbeitet weiter mit dem alten Pin — das ist sicher" >&2
  echo "FEHLER: (er schuetzt dann eher zu viel), aber es gehoert repariert." >&2
  exit 1
fi

echo "${TARGET} geschrieben: ${VERS} (${GRUND})"
