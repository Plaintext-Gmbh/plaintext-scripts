#!/usr/bin/env bash
# wochenpatch/lauf.sh — der woechentliche Patch-Release aller Anwendungen (Karte 1340).
#
# Auftrag Daniel, 28.09.2026: den Ablauf dieses Tages (Renovate-Updates, bauen, testen, releasen,
# deployen) als Skripte in plaintext-scripts, jeden Sonntag per Woodpecker-Job.
# SonarQube ist NICHT Teil davon (Daniel: "geht natuerlich nicht per Script").
#
# AUFRUF
#   wochenpatch/lauf.sh                  # Modus aus WOCHENPATCH_MODUS, Vorgabe "pr"
#
# MODI (WOCHENPATCH_MODUS)
#   pr         Je Repo ein PR "wochenpatch/<datum>" mit allen Patch-Updates. Nichts wird gemergt.
#              Die Kinder werden gegen den AKTUELLEN root-Stand gepatcht.
#   ausrollen  Wie am 28.09.2026 von Hand: root -> app -> guild -> schuetu nacheinander mergen,
#              Release und Rollout abwarten (/nosec/version), die Kinder bekommen die neue
#              root- bzw. app-Version. iot wird gemergt, aber mit [skip ci] NICHT ausgerollt.
#              ProjectMind bekommt einen Patch-Release (Tag).
#   Der Modus "ausrollen" braucht die ausdrueckliche Freigabe Daniels (Karte 1340).
#
# LEITPLANKEN
#   - Nur Patch-Spruenge (allowMinor=false), Majors bleiben dem Renovate-Dashboard.
#   - Abbruch bei der ersten roten Pruefung: der PR bleibt offen, nichts danach wird gemergt.
#   - Kein Merge, solange im Repo ein fremder PR offen ist, der nicht von Renovate stammt.
#   - Rollout gilt erst mit /nosec/version als belegt, nicht mit einem gruenen Job.
#   - Am Ende eine Pushover-Meldung mit dem Bericht.
#
# UMGEBUNG (Woodpecker-Secrets): GH_TOKEN (PR, Merge, Workflow-Dispatch), PUSHOVER_APP_TOKEN,
# PUSHOVER_USER_KEY. Werkzeuge: git, gh, mvn (Java 25), python3, curl; fuer ProjectMind cargo, node 22.
set -euo pipefail
HIER="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wochenpatch/lib.sh
. "$HIER/lib.sh"
MODUS="${WOCHENPATCH_MODUS:-pr}"
# TEIL: maven | projectmind | alles — der Woodpecker-Job faehrt beide Teile in eigenen Images.
TEIL="${WOCHENPATCH_TEIL:-alles}"
ARBEIT="${WOCHENPATCH_ARBEIT:-$(mktemp -d)}"
[ "$TEIL" = projectmind ] || : > "$WP_BERICHT"   # der zweite Teil haengt an den Bericht an
bericht "Wochenpatch $WP_DATUM, Modus $MODUS, Teil $TEIL"

# repo | Versionsadresse (leer = kein Rollout-Beleg) | ausrollen ja/nein
REPOS="
plaintext-root||ja
plaintext-app|https://app.plaintext.ch/nosec/version|ja
plaintext-guild|https://guild.plaintext.ch/nosec/version|ja
plaintext-schuetu|https://schuelerturnier.plaintext.ch/nosec/version|ja
plaintext-iot||nein
"
# fwtool: seit 23.09.2026 auf GitHub archiviert (read-only) — bewusst nicht in der Liste.

klone() {   # $1 = repo
    local ziel="$ARBEIT/$1"
    rm -rf "$ziel"
    git clone -q --depth 50 "https://x-access-token:${GH_TOKEN}@github.com/$WP_ORG/$1.git" "$ziel"
    git -C "$ziel" config user.name "${WP_GIT_NAME:-plaintext wochenpatch}"
    git -C "$ziel" config user.email "${WP_GIT_MAIL:-renovate@plaintext.ch}"
    git -C "$ziel" checkout -q -b "$WP_ZWEIG"
    echo "$ziel"
}

fremde_prs() {   # offene PRs, die weder von Renovate noch von diesem Lauf stammen
    gh pr list -R "$WP_ORG/$1" --state open --json headRefName \
        --jq '[.[] | select((.headRefName|startswith("renovate/")|not) and (.headRefName|startswith("wochenpatch/")|not))] | length'
}

pruefe_lokal() {   # $1 = Verzeichnis, $2 = repo
    ( cd "$1"
      [ -f scripts/docs/gen-readme-tabellen.py ] && python3 scripts/docs/gen-readme-tabellen.py >&2
      mvn -q -B -DskipTests -Dmaven.build.cache.enabled=false test-compile >&2 )
}

# Ein Maven-Repo patchen, PR eroeffnen, im Modus "ausrollen" mergen und Release/Rollout abwarten.
# Gibt die neue Release-Version auf stdout aus (leer, wenn nichts gemergt wurde).
maven_repo() {   # $1 repo  $2 versions-url  $3 ausrollen  $4 root-version  $5 app-version
    local repo="$1" url="$2" roll="$3" root="${4:-}" app="${5:-}" dir aenderungen owasp pr nr alt neu betreff
    dir="$(klone "$repo")"
    local optionen=()
    [ -n "$root" ] && optionen+=(--parent "$root")
    [ -n "$app" ] && optionen+=(--app "$app")
    aenderungen="$("$HIER/maven-patch.sh" "$dir" "${optionen[@]}")"
    owasp="$("$HIER/owasp-tote-suppressionen.sh" "$dir")"
    if git -C "$dir" diff --quiet; then bericht "$repo: nichts zu patchen"; return 0; fi
    pruefe_lokal "$dir" "$repo" || die "$repo: test-compile rot, kein PR"
    betreff="chore(deps): Wochenpatch $WP_DATUM"
    [ "$roll" = nein ] && [ "$MODUS" = ausrollen ] && betreff="$betreff [skip ci]"
    git -C "$dir" add -A
    git -C "$dir" commit -q -F - <<MSG
$betreff

Patch-Updates (wochenpatch/lauf.sh, Karte 1340):
$aenderungen
${owasp:+
Entfernte OWASP-Suppressionen (gepinnte Version nicht mehr auf dem Klassenpfad):
$owasp}
MSG
    git -C "$dir" push -q -u origin "$WP_ZWEIG"
    pr="$(gh pr create -R "$WP_ORG/$repo" --head "$WP_ZWEIG" --title "$betreff" \
          --body "$(printf 'Automatischer Wochenpatch (Karte 1340).\n\n```\n%s\n```\n%s' "$aenderungen" "${owasp:+OWASP entfernt: $owasp}")")"
    nr="${pr##*/}"
    bericht "$repo: PR #$nr — $(tr '\n' ';' <<<"$aenderungen")"
    [ "$MODUS" = ausrollen ] || return 0

    warte_auf_pruefungen "$repo" "$nr" 120 || die "$repo: Pruefungen von PR #$nr nicht gruen, Lauf endet hier"
    [ "$(fremde_prs "$repo")" = 0 ] || die "$repo: fremder PR offen, kein Merge"
    alt="$(release_version "$dir")"
    gh pr merge "$nr" -R "$WP_ORG/$repo" --squash --delete-branch --subject "$betreff (#$nr)"
    if [ "$roll" = nein ]; then bericht "$repo: gemergt ohne Rollout ([skip ci])"; return 0; fi
    for _ in $(seq 1 60); do
        neu="$(release_version "$dir")"; [ -n "$neu" ] && [ "$neu" != "$alt" ] && break; sleep 30
    done
    [ -n "$neu" ] && [ "$neu" != "$alt" ] || die "$repo: kein Release-Commit nach dem Merge"
    if [ -n "$url" ]; then warte_auf_rollout "$url" "$neu" || die "$repo: $neu nicht live"; fi
    bericht "$repo: $alt -> $neu${url:+ (live belegt)}"
    echo "$neu"
}

projectmind() {
    local dir nr bot
    dir="$(klone projectmind)"
    "$HIER/projectmind-patch.sh" "$dir" >/dev/null || die "projectmind: Pruefungen rot"
    if git -C "$dir" diff --quiet; then bericht "projectmind: nichts zu patchen"; return 0; fi
    git -C "$dir" add Cargo.lock app/package.json app/pnpm-lock.yaml
    git -C "$dir" commit -q -m "chore(deps): Wochenpatch $WP_DATUM (cargo update, pnpm update)"
    git -C "$dir" push -q -u origin "$WP_ZWEIG"
    nr="$(gh pr create -R "$WP_ORG/projectmind" --head "$WP_ZWEIG" --title "chore(deps): Wochenpatch $WP_DATUM" --body "Automatischer Wochenpatch (Karte 1340)." | sed 's|.*/||')"
    bericht "projectmind: PR #$nr"
    [ "$MODUS" = ausrollen ] || return 0
    warte_auf_pruefungen projectmind "$nr" 60 || die "projectmind: PR #$nr nicht gruen"
    gh pr merge "$nr" -R "$WP_ORG/projectmind" --squash --delete-branch
    # Release: der Bot-PR startet seine Pflichtpruefungen nicht selbst und laesst Cargo.lock aus.
    gh workflow run release.yml -R "$WP_ORG/projectmind" -f bump=patch
    for _ in $(seq 1 40); do
        bot="$(gh pr list -R "$WP_ORG/projectmind" --state open --json number,headRefName --jq '[.[]|select(.headRefName|startswith("release/v"))][0].headRefName // ""')"
        [ -n "$bot" ] && break; sleep 15
    done
    [ -n "$bot" ] || die "projectmind: kein Release-PR entstanden"
    git -C "$dir" fetch -q origin "+refs/heads/$bot:refs/remotes/origin/$bot"
    git -C "$dir" checkout -q -B "$bot" "origin/$bot"
    ( cd "$dir" && cargo update -w >&2 )
    git -C "$dir" commit -q -a -m "chore(release): Cargo.lock nachgezogen" || git -C "$dir" commit -q --allow-empty -m "ci: Pflichtpruefungen anstossen"
    git -C "$dir" push -q origin "$bot"
    nr="$(gh pr list -R "$WP_ORG/projectmind" --head "$bot" --json number --jq '.[0].number')"
    warte_auf_pruefungen projectmind "$nr" 60 || die "projectmind: Release-PR #$nr nicht gruen"
    gh pr merge "$nr" -R "$WP_ORG/projectmind" --squash --delete-branch
    git -C "$dir" fetch -q origin master
    git -C "$dir" tag -a "${bot#release/}" origin/master -m "ProjectMind ${bot#release/} (Wochenpatch $WP_DATUM)"
    git -C "$dir" push -q origin "${bot#release/}"
    bericht "projectmind: ${bot#release/} getaggt, Release-Build laeuft"
}

melden() {
    local status="$1"
    [ -x "$HIER/../pushover" ] && [ -n "${PUSHOVER_APP_TOKEN:-}" ] \
        && "$HIER/../pushover" -t "Wochenpatch $WP_DATUM: $status" "$(cat "$WP_BERICHT")" || true
}
trap 'melden ABGEBROCHEN' ERR

ROOT_NEU=""; APP_NEU=""
[ "$TEIL" = projectmind ] || while IFS='|' read -r repo url roll; do
    [ -n "$repo" ] || continue
    case "$repo" in
        plaintext-root)  ROOT_NEU="$(maven_repo "$repo" "$url" "$roll")" ;;
        plaintext-app)   APP_NEU="$(maven_repo "$repo" "$url" "$roll" "$ROOT_NEU")" ;;
        plaintext-guild) maven_repo "$repo" "$url" "$roll" "$ROOT_NEU" "$APP_NEU" >/dev/null ;;
        *)               maven_repo "$repo" "$url" "$roll" "$ROOT_NEU" >/dev/null ;;
    esac
    # Das Artefakt muss vollstaendig oben sein, bevor ein Kind darauf zeigt (deployAtEnd).
    [ "$repo" = plaintext-root ] && [ -n "$ROOT_NEU" ] && { warte_auf_artefakt ch/plaintext plaintext-root-parent "$ROOT_NEU" || die "root $ROOT_NEU nicht im Paket-Repo"; }
    [ "$repo" = plaintext-app ] && [ -n "$APP_NEU" ] && { warte_auf_artefakt ch/plaintext plaintext-parent "$APP_NEU" || die "app $APP_NEU nicht im Paket-Repo"; }
done <<<"$REPOS"
[ "$TEIL" = maven ] || projectmind
trap - ERR
[ "$TEIL" = maven ] || melden fertig
cat "$WP_BERICHT"
