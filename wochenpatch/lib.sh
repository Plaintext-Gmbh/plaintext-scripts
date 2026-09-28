#!/usr/bin/env bash
# wochenpatch/lib.sh — gemeinsame Helfer fuer den woechentlichen Patch-Release (Karte 1340).
#
# Wird von den uebrigen wochenpatch-Skripten GESOURCT, nicht direkt aufgerufen.
# plaintext-scripts ist oeffentlich: hier steht kein Token. Alles Geheime kommt aus der Umgebung
# (Woodpecker-Secrets): GH_TOKEN fuer gh, PUSHOVER_* fuer ../pushover.

WP_ORG="${WP_ORG:-Plaintext-Gmbh}"
WP_DATUM="${WP_DATUM:-$(date +%Y-%m-%d)}"
WP_ZWEIG="${WP_ZWEIG:-wochenpatch/$WP_DATUM}"
WP_BERICHT="${WP_BERICHT:-${TMPDIR:-/tmp}/wochenpatch-bericht.txt}"

log()     { printf '[wochenpatch %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
bericht() { printf '%s\n' "$*" >> "$WP_BERICHT"; log "$*"; }
die()     { bericht "ABBRUCH: $*"; exit 1; }

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
