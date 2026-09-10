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
# UNTERSCHIED ZUM GITHUB-SKRIPT: kein `gh`, kein `jq` und kein Python. Gesprochen wird direkt
# mit der REST-API (curl), ausgewertet wird mit grep/sed/base64.
#
# WARUM OHNE PYTHON (gemessen am 09.09.2026): `maven:3.9-eclipse-temurin-25` — das Image, in
# dem die Woodpecker-Steps dieses Repos laufen — bringt bash und curl mit, aber KEIN python3
# (`which python3` leer, Ubuntu 24.04). Ein `apt-get install` je Lauf waere der teurere Weg,
# sobald das Paket-Repo einmal klemmt. Die JSON-Auswertung ist hier klein genug fuer sed:
# gelesen werden zwei Felder, geschrieben wird ein Objekt aus drei kontrollierten Werten.
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

# ── grep_q: `grep -q` unter `pipefail` ist eine Falle — hier mit `set -e` daneben ─────
# `grep -q` steigt beim ERSTEN Treffer aus und schliesst seine Eingabe. Der Schreiber links
# blockiert dann in `write()` und bekommt SIGPIPE, Rueckgabewert 141; `pipefail` reicht das als
# Pipeline-Fehler durch. Ausgeloest wird es, sobald der Schreiber nach dem Treffer noch
# schreiben will — also ab Pipe-Puffer-Groesse (64 KiB). Gemessen Karte 1161: bei 91 KB 17 von
# 20 Laeufen, bei 194 KB 0 von 20.
#
# DIE BEDINGUNG IST ENGER, ALS SIE KLINGT — gemessen am 10.09.2026 an der echten API, nicht
# abgeleitet. `grep` ist ZEILENorientiert und kann erst aussteigen, wenn es eine VOLLSTAENDIGE
# Trefferzeile gelesen hat. Es braucht also mehr als 64 KB NACH der Trefferzeile, nicht bloss
# eine grosse Antwort. Die Contents-Antwort von GitHub kommt formatiert, 17 Zeilen, und
# `"content"` steht auf Zeile 11 — das ist die riesige base64-Zeile, danach folgen nur noch
# sechs kurze. Gemessen mit einer 227-KB-Antwort (tui-build-logic.sh): `grep -q` 20 von 20
# richtig. Diese Stelle war also NICHT ausloesbar; Karte 1161 hat sie zu scharf eingeschaetzt.
#
# `grep_q` steht hier trotzdem, und zwar nicht aus Symmetrie: die Reihenfolge und die
# Feldgroessen dieser Antwort sind NICHT von uns kontrolliert. Kommt drueben je ein grosses Feld
# NACH `content` dazu, kippt die Pruefung — und dann faellt sie auf "die API hat nicht
# bestaetigt": der Versuch gilt als fehlgeschlagen, der Pin wird bis zum Abbruch neu
# geschrieben. Mit `grep_q` kann das nicht passieren, unabhaengig davon, was GitHub sendet.
#
# `grep_q` liest die Eingabe VOLLSTAENDIG (`grep -c`) und meldet denselben Rueckgabewert wie
# `grep -q`: 0 = mindestens ein Treffer, 1 = keiner. Optionen und Muster gehen unveraendert
# durch, die Aussage jeder Pruefung bleibt gleich — nur der Wettlauf ist weg. Wortgleich mit dem
# Helfer aus den Testsuiten (test-release-lock.sh u. a., Karte 1155, PR #113/f6ed1ef); bewusst
# derselbe Name und derselbe Rumpf, statt eine zweite Variante zu erfinden.
#
# Aus demselben Grund steht unten `| sed -n 1p` statt `| head -1`: `head` steigt nach der ersten
# Zeile aus, `sed -n 1p` liest bis EOF. Auch das ist hier VORSORGE, kein heutiger Defekt — der
# Schreiber ist jeweils ein `sed`, das genau eine Zeile liefert, und wo nichts nachkommt gibt es
# keinen SIGPIPE. Die Bauform ist der Punkt, nicht die heutige Datenmenge.
grep_q() { local n; n=$(grep -c "$@") || true; [ "${n:-0}" -gt 0 ]; }

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
# Aus der Contents-Antwort werden genau zwei Felder gebraucht: `sha` (fuer das optimistische
# Schreiben) und `content` (base64, mit \n-Escapes im JSON). Beide Muster sind an der Antwort
# von GitHub gemessen, nicht geraten; fehlt die Datei drueben, bleiben beide leer und das
# Skript legt sie an.
RESP="$(api GET "/repos/${MVN_REPO}/contents/${TARGET}?ref=${PIN_BRANCH}" || true)"
SHA="$(printf '%s' "$RESP" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | sed -n 1p)"
ALT="$(printf '%s' "$RESP" \
       | sed -n 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
       | sed 's/\\n//g' | base64 -d 2>/dev/null || true)"
OLD_VERS="$(printf '%s' "$ALT" | sed -n 's/^versions=//p' | sed -n 1p)"
OLD_UPD="$(printf '%s' "$ALT" | sed -n 's/^updated=//p' | sed -n 1p)"
OLD_UPD="${OLD_UPD:-1970-01-01T00:00:00Z}"

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
  INHALT="$(printf 'repo=%s\nversions=%s\nupdated=%s\ncommit=%s\n' \
                   "$REPO_NAME" "$VERS" "$NOW" "${COMMIT_SHA:0:9}" | base64 -w0)"
  RUMPF="$(mktemp)"
  # Von Hand gebautes JSON: alle drei Werte sind kontrolliert — Repo-Name und Version sind
  # oben gegen ein Muster geprueft, der Inhalt ist base64. Es kommt nichts aus einer fremden
  # Quelle hinein, das hier escaped werden muesste.
  if [ -n "$SHA" ]; then
    printf '{"branch":"%s","message":"chore(pins): %s benutzt %s [skip ci]","content":"%s","sha":"%s"}' \
           "$PIN_BRANCH" "$REPO_NAME" "$VERS" "$INHALT" "$SHA" > "$RUMPF"
  else
    printf '{"branch":"%s","message":"chore(pins): %s benutzt %s [skip ci]","content":"%s"}' \
           "$PIN_BRANCH" "$REPO_NAME" "$VERS" "$INHALT" > "$RUMPF"
  fi

  ANTWORT="$(api PUT "/repos/${MVN_REPO}/contents/${TARGET}" "$RUMPF" || true)"
  rm -f "$RUMPF"
  if printf '%s' "$ANTWORT" | grep_q '"content"'; then ok=true; break; fi

  # ${...:0:300} statt `| head -c 300`: keine Pipe, also gar kein SIGPIPE-Risiko. `head -c`
  # steigt nach 300 Byte aus und liesse `printf` in eine geschlossene Pipe schreiben.
  echo "WARNUNG: Versuch ${versuch} fehlgeschlagen: ${ANTWORT:0:300}" >&2
  sleep $(( versuch * 4 ))
  SHA="$(api GET "/repos/${MVN_REPO}/contents/${TARGET}?ref=${PIN_BRANCH}" \
         | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | sed -n 1p)"
done

if [ "$ok" != true ]; then
  echo "FEHLER: ${TARGET} auf Branch ${PIN_BRANCH} von ${MVN_REPO} konnte nicht geschrieben werden." >&2
  echo "FEHLER: Der Aufraeum-Workflow drueben arbeitet weiter mit dem alten Pin — das ist sicher" >&2
  echo "FEHLER: (er schuetzt dann eher zu viel), aber es gehoert repariert." >&2
  exit 1
fi

echo "${TARGET} geschrieben: ${VERS} (${GRUND})"
