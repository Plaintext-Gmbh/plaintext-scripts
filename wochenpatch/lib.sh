#!/usr/bin/env bash
# wochenpatch/lib.sh — gemeinsame Helfer fuer den woechentlichen Patch-Release (Karte 1340).
#
# Wird von den uebrigen wochenpatch-Skripten GESOURCT, nicht direkt aufgerufen.
# plaintext-scripts ist oeffentlich: hier steht kein Token. Alles Geheime kommt aus der Umgebung
# (Woodpecker-Secrets): GH_TOKEN fuer gh und git, WOODPECKER_TOKEN fuer den Blick auf laufende
# Deploys, PUSHOVER_* fuer ../pushover.

WP_ORG="${WP_ORG:-Plaintext-Gmbh}"
WP_DATUM="${WP_DATUM:-$(date +%Y-%m-%d)}"
WP_ZWEIG="${WP_ZWEIG:-wochenpatch/$WP_DATUM}"
WP_BERICHT="${WP_BERICHT:-${TMPDIR:-/tmp}/wochenpatch-bericht.txt}"
# Woher geklont wird. Die Tests zeigen hier auf lokale Repos, der Lauf auf GitHub.
WP_GIT_BASIS="${WP_GIT_BASIS:-https://github.com/$WP_ORG}"
WP_WOODPECKER_URL="${WP_WOODPECKER_URL:-https://ci.plaintext.ch}"
# Diese Repos deployen per Push auf master; vor jedem Merge darf in keinem ein Lauf offen sein.
WP_DEPLOY_REPOS="${WP_DEPLOY_REPOS:-plaintext-root plaintext-app plaintext-guild plaintext-schuetu plaintext-iot}"

log()     { printf '[wochenpatch %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
bericht() { printf '%s\n' "$*" >> "$WP_BERICHT"; log "$*"; }
die()     { bericht "ABBRUCH: $*"; exit 1; }

# git-Zugang ueber einen credential-Helper aus der Umgebung statt Token in der Klon-URL: so steht
# das Token weder in .git/config noch in einer Fehlermeldung von git (plaintext-scripts ist
# oeffentlich, die Woodpecker-Logs sind es fuer Org-Mitglieder).
git_zugang() {
    [ -n "${GH_TOKEN:-}" ] || return 0
    export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1
    export GIT_CONFIG_KEY_0="credential.https://github.com.helper"
    # shellcheck disable=SC2016  # $GH_TOKEN wertet erst der Helper aus, nicht diese Zeile
    export GIT_CONFIG_VALUE_0='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
}

# Maven-Zugang in der CI. Die Releases liegen offen lesbar auf maven.plaintext.ch; der Fallback
# GitHub Packages (Server-Id "plaintext") verlangt aber Zugangsdaten. NICHT nach
# /root/.m2/settings.xml: das ist das Volume woodpecker-m2, das JEDER Step JEDES Repos sieht
# (Karte 313). /tmp liegt in der Schreibschicht dieses einen Containers.
maven_einrichten() {
    [ -n "${CI:-}" ] && [ -n "${GH_TOKEN:-}" ] || return 0
    local d="${TMPDIR:-/tmp}/wochenpatch-m2"
    mkdir -p "$d" && chmod 700 "$d"
    ( umask 077
      printf '%s\n' '<settings><servers>' \
        "<server><id>plaintext</id><username>daniel-marthaler</username><password>${GH_TOKEN}</password></server>" \
        '</servers></settings>' > "$d/settings.xml" )
    export MAVEN_ARGS="-s $d/settings.xml"
}

# Steht in einem der Deploy-Repos ein Woodpecker-Lauf auf master noch aus oder laeuft er?
# Das ist der maschinenlesbare Teil des Deploy-Slots (Karte 413): der Slot selbst liegt im
# Nextcloud-Deck, an das der Job keinen Zugang hat. Rueckgabe 0 = Ruhe, 1 = es laeuft etwas
# (Liste auf stderr), 3 = nicht pruefbar (kein Token, API nicht erreichbar).
deploy_laeuft_nicht() {
    [ -n "${WOODPECKER_TOKEN:-}" ] || { log "WOODPECKER_TOKEN fehlt"; return 3; }
    local repo id json laeuft=0
    for repo in $WP_DEPLOY_REPOS; do
        id="$(curl -fsS -m 20 -A curl/8.0 -H "Authorization: Bearer $WOODPECKER_TOKEN" \
              "$WP_WOODPECKER_URL/api/repos/lookup/$WP_ORG/$repo" 2>/dev/null \
              | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null)" \
            || { log "Woodpecker-API: $repo nicht auffindbar"; return 3; }
        json="$(curl -fsS -m 20 -A curl/8.0 -H "Authorization: Bearer $WOODPECKER_TOKEN" \
              "$WP_WOODPECKER_URL/api/repos/$id/pipelines?page=1&perPage=10" 2>/dev/null)" \
            || { log "Woodpecker-API: Laeufe von $repo nicht lesbar"; return 3; }
        if ! python3 -c '
import json,sys
offen=[p for p in json.loads(sys.argv[1]) if p.get("branch")=="master"
       and p.get("event") in ("push","manual","deployment")
       and p.get("status") in ("pending","running","blocked")]
for p in offen: print("  %s #%s %s %s" % (sys.argv[2], p["number"], p["event"], p["status"]), file=sys.stderr)
sys.exit(1 if offen else 0)' "$json" "$repo"; then laeuft=1; fi
    done
    return "$laeuft"
}

# Wartet bis zu $1 Minuten auf deploy_laeuft_nicht. 0 = Ruhe, sonst der letzte Rueckgabewert.
warte_auf_deploy_ruhe() {
    local minuten="${1:-60}" ende rc
    ende=$(( $(date +%s) + minuten * 60 ))
    while :; do
        rc=0; deploy_laeuft_nicht || rc=$?
        [ "$rc" = 1 ] || return "$rc"
        [ "$(date +%s)" -lt "$ende" ] || return 1
        log "ein Deploy laeuft noch, warte"; sleep 60
    done
}

# Schreibt die roten Pruefungen eines PRs samt Link in den Bericht. Die fehlgeschlagenen Tests
# eines Woodpecker-Laufs stehen im Allure-JSON auf dem NAS (http://192.168.1.224:1155/<repo>/
# <lauf>/data/suites.json) — log_entries ist bei frischen Laeufen oft leer.
pruefungen_befund() {   # $1 repo, $2 PR
    gh pr checks "$2" -R "$WP_ORG/$1" 2>/dev/null \
        | awk -F'\t' '$2 ~ /^(fail|cancel)/ {print "  rot: " $1 " " $4}' >> "$WP_BERICHT" || true
}

# Wartet, bis alle Pruefungen eines PRs fertig sind. Rueckgabe 0 = alles gruen (oder skipping),
# 1 = mindestens eine rot, 2 = Zeitlimit. $1 = repo, $2 = PR-Nummer, $3 = Minuten (Vorgabe 90).
warte_auf_pruefungen() {
    local repo="$1" pr="$2" minuten="${3:-90}" ende stand
    ende=$(( $(date +%s) + minuten * 60 ))
    sleep 60   # Woodpecker meldet die ersten Status erst nach dem Klonen
    while [ "$(date +%s)" -lt "$ende" ]; do
        stand="$(gh pr checks "$pr" -R "$WP_ORG/$repo" 2>/dev/null | awk -F'\t' '{print $2}' || true)"
        if [ -n "$stand" ] && ! grep -q -E '^(pending|queued|in_progress)$' <<<"$stand"; then
            grep -q -E '^(fail|cancel)' <<<"$stand" && return 1
            return 0
        fi
        sleep 30
    done
    return 2
}

# Wartet, bis eine Version im Paket-Repo vollstaendig abrufbar ist (deployAtEnd: erst dann
# liegen ALLE Module oben). $1 = groupId-Pfad (ch/plaintext), $2 = artifactId, $3 = Version.
warte_auf_artefakt() {
    local pfad="$1" art="$2" ver="$3" url
    url="${WP_MAVEN_URL:-https://maven.plaintext.ch/releases}/$pfad/$art/$ver/$art-$ver.pom"
    for _ in $(seq 1 120); do
        curl -fsS -A curl/8.0 -o /dev/null "$url" 2>/dev/null && return 0
        sleep 30
    done
    return 1
}

# Wartet, bis /nosec/version die erwartete Version meldet. $1 = URL, $2 = Version.
warte_auf_rollout() {
    local url="$1" ver="$2" ist=""
    for _ in $(seq 1 80); do
        ist="$(curl -fsS -m 15 -A curl/8.0 "$url" 2>/dev/null | head -c 60 || true)"
        [ "$ist" = "$ver" ] && return 0
        sleep 30
    done
    bericht "  Rollout nicht belegt: $url meldet '$ist', erwartet $ver"
    return 1
}

# Liest die Version aus dem letzten "Release version X"-Commit auf master. $1 = Klonverzeichnis.
release_version() {
    git -C "$1" fetch -q origin master
    git -C "$1" log origin/master -20 --format=%s | sed -n 's/^Release version \([0-9.]*\).*/\1/p' | head -1
}
