#!/usr/bin/env bash
# wochenpatch/lauf.sh — der woechentliche Patch-Release aller Anwendungen (Karte 1340).
#
# Auftrag Daniel, 28.09.2026: den Ablauf dieses Tages (Renovate-Updates, bauen, testen, releasen,
# deployen) als Skripte in plaintext-scripts, jeden Sonntag per Woodpecker-Job.
# SonarQube ist NICHT Teil davon (Daniel: "geht natuerlich nicht per Script").
#
# AUFRUF
#   wochenpatch/lauf.sh                  # Modus aus WOCHENPATCH_MODUS, Vorgabe "trocken"
#
# MODI (WOCHENPATCH_MODUS)
#   trocken    Vorflug ohne Wirkung: klonen, patchen, OWASP pruefen, test-compile, offene fremde
#              PRs und laufende Deploys ansehen — und je Repo berichten, was ein echter Lauf
#              taete. Kein Push, kein PR, kein Merge, keine Pushover-Meldung.
#   pr         Je Repo ein PR "wochenpatch/<datum>" mit allen Patch-Updates. Nichts wird gemergt.
#              Die Kinder werden gegen den AKTUELLEN root-Stand gepatcht.
#   ausrollen  Wie am 28.09.2026 von Hand: root -> app -> guild -> schuetu nacheinander mergen,
#              Release und Rollout abwarten (/nosec/version), die Kinder bekommen die neue
#              root- bzw. app-Version. iot wird gemergt, aber mit [skip ci] NICHT ausgerollt.
#              ProjectMind bekommt einen Patch-Release (Tag).
#   "ausrollen" hat Daniel am 29.09.2026 freigegeben (Karte 1340); der Sonntags-Cron faehrt ihn.
#
# LEITPLANKEN
#   - Patch- und Minor-Spruenge (gleiche erste Stelle), Majors bleiben dem Renovate-Dashboard;
#     Datums-/Kalenderversionen nie automatisch (Entscheid Daniel 29.09.2026, maven-patch.sh).
#   - Abbruch bei der ersten roten Pruefung: der PR bleibt offen, nichts danach wird gemergt.
#   - Kein Merge, solange im Repo ein fremder PR offen ist, der nicht von Renovate stammt.
#   - Vor jedem Merge: kein offener Woodpecker-Lauf auf master in den Deploy-Repos (der
#     maschinenlesbare Teil des Deploy-Slots, Karte 413; das Deck selbst sieht der Job nicht).
#   - Rollout gilt erst mit /nosec/version als belegt, nicht mit einem gruenen Job.
#   - Am Ende eine Pushover-Meldung mit dem Bericht.
#
# UMGEBUNG (Woodpecker-Secrets): GH_TOKEN (Klon, PR, Merge, Workflow-Dispatch), WOODPECKER_TOKEN
# (laufende Deploys lesen), PUSHOVER_APP_TOKEN, PUSHOVER_USER_KEY. Werkzeuge: git, gh, mvn (Java 25), python3, curl; fuer ProjectMind cargo, node 22.
set -euo pipefail
# Ohne inherit_errexit liefe eine Funktion in $(...) nach einem Fehler einfach weiter —
# maven_repo laeuft genau so (ROOT_NEU="$(maven_repo ...)").
shopt -s inherit_errexit
HIER="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wochenpatch/lib.sh
. "$HIER/lib.sh"
MODUS="${WOCHENPATCH_MODUS:-trocken}"
case "$MODUS" in trocken|pr|ausrollen) ;; *) echo "unbekannter Modus: $MODUS" >&2; exit 2 ;; esac
# TEIL: maven | projectmind | alles — der Woodpecker-Job faehrt beide Teile in eigenen Images.
TEIL="${WOCHENPATCH_TEIL:-alles}"
ARBEIT="${WOCHENPATCH_ARBEIT:-$(mktemp -d)}"
if [ "$TEIL" != projectmind ]; then : > "$WP_BERICHT"; fi   # der zweite Teil haengt an
bericht "Wochenpatch $WP_DATUM, Modus $MODUS, Teil $TEIL"
git_zugang
maven_einrichten

# repo | Versionsadresse (leer = kein Rollout-Beleg) | ausrollen ja/nein | Blatt-Artefakt
# Das Blatt-Artefakt (ein Jar, das die Kinder brauchen) belegt, dass ein Release VOLLSTAENDIG im
# Paket-Repo liegt; der Parent-POM liegt frueher oben (Lauf 10/#7, 29.09.2026). Nur Repos, deren
# Release andere Repos verwenden, haben eines — und nur sie reichen ihre Version weiter.
REPOS="
plaintext-root||ja|plaintext-root-watch
plaintext-app|https://app.plaintext.ch/nosec/version|ja|plaintext-z-kontakte
plaintext-guild|https://guild.plaintext.ch/nosec/version|ja|
plaintext-schuetu|https://schuelerturnier.plaintext.ch/nosec/version|ja|
plaintext-iot||nein|
"
# fwtool: seit 23.09.2026 auf GitHub archiviert (read-only) — bewusst nicht in der Liste.

klone() {   # $1 = repo
    local ziel="$ARBEIT/$1"
    rm -rf "$ziel"
    git clone -q --depth 50 "$WP_GIT_BASIS/$1.git" "$ziel" >&2
    git -C "$ziel" config user.name "${WP_GIT_NAME:-plaintext wochenpatch}"
    git -C "$ziel" config user.email "${WP_GIT_MAIL:-renovate@plaintext.ch}"
    git -C "$ziel" checkout -q -b "$WP_ZWEIG"
    echo "$ziel"
}

offene_prs() {   # $1 repo -> je offenem PR eine Zeile "<nr> <zweig>"; Rueckgabe != 0, wenn gh scheitert
    gh pr list -R "$WP_ORG/$1" --state open --limit 100 --json number,headRefName \
        --jq '.[] | "\(.number) \(.headRefName)"'
}

# Fremd ist ein offener PR, der weder von Renovate noch von einem Wochenpatch noch vom Auto-Bump
# stammt. Auto-Bump-PRs (chore/root-autobump) setzen dieselbe Root-Version wie dieser Lauf und
# werden geschlossen statt den Lauf anzuhalten (Entscheid Daniel 04.10.2026, Karte 1419).
fremde_pr_liste() {   # $1 repo -> je fremdem PR "#<nr> <zweig>"
    local alle nr zweig
    alle="$(offene_prs "$1")" || return 1
    while read -r nr zweig; do
        [ -n "$nr" ] || continue
        case "$zweig" in renovate/*|wochenpatch/*|chore/root-autobump*) ;; *) echo "#$nr $zweig" ;; esac
    done <<<"$alle"
}

# Bricht ab, wenn im Repo ein fremder PR offen ist — und nennt ihn. Ein gh-Fehler zaehlt als
# "nicht pruefbar" und haelt den Merge ebenso an (vorher: gh-Fehler = leere Zahl = Abbruch ohne Grund).
pruefe_fremde() {   # $1 repo  $2 Zusatz fuer die Meldung
    local liste
    liste="$(fremde_pr_liste "$1")" || die "$1: offene PRs nicht lesbar (gh), kein Merge"
    [ -z "$liste" ] || die "$1: fremde PRs offen ($(tr '\n' ' ' <<<"$liste" | sed 's/ $//'))${2:+, $2}"
}

autobumps_schliessen() {   # $1 repo — im Modus ausrollen schliessen, sonst nur berichten
    local alle nr zweig
    alle="$(offene_prs "$1")" || die "$1: offene PRs nicht lesbar (gh)"
    while read -r nr zweig; do
        case "$zweig" in chore/root-autobump*) ;; *) continue ;; esac
        if [ "$MODUS" = ausrollen ]; then
            gh pr close "$nr" -R "$WP_ORG/$1" --comment "Überholt durch den Wochenpatch $WP_DATUM: er setzt dieselbe plaintext-root-Version (Karte 1419)." >&2 \
                || die "$1: Auto-Bump-PR #$nr liess sich nicht schliessen"
            bericht "$1: Auto-Bump-PR #$nr geschlossen (überholt)"
        else
            bericht "$1: Auto-Bump-PR #$nr wuerde geschlossen (überholt)"
        fi
    done <<<"$alle"
}

# Vorpruefung (Entscheid Daniel 04.10.2026, Karte 1419): VOR dem root-Merge muessen alle Repos
# mergebar sein. Am 04.10. (Lauf 10/#23) war root schon released, als app an fremden PRs scheiterte.
# Im Modus ausrollen bricht ein fremder PR oder eine unklare Deploy-Lage hier ab, bevor irgendetwas
# veraendert ist; in trocken und pr steht der Befund nur im Bericht.
vorpruefung() {
    local repo url roll blatt liste blockiert=""
    while IFS='|' read -r repo url roll blatt; do
        [ -n "$repo" ] || continue
        liste="$(fremde_pr_liste "$repo")" || die "Vorpruefung: $repo: offene PRs nicht lesbar (gh), nichts veraendert"
        if [ -n "$liste" ]; then
            blockiert="$blockiert $repo ($(tr '\n' ' ' <<<"$liste" | sed 's/ $//'))"
            bericht "Vorpruefung: $repo: fremde PRs offen: $(tr '\n' ' ' <<<"$liste")"
        fi
    done <<<"$REPOS"
    if [ "$MODUS" = ausrollen ]; then
        [ -z "$blockiert" ] || die "Vorpruefung: fremde PRs offen in$blockiert — nichts gemergt, nichts released"
        warte_auf_deploy_ruhe 60 || die "Vorpruefung: Deploy-Lage unklar oder belegt — nichts gemergt"
    fi
    [ -n "$blockiert" ] || bericht "Vorpruefung: keine fremden PRs offen"
    while IFS='|' read -r repo url roll blatt; do
        [ -n "$repo" ] || continue
        autobumps_schliessen "$repo"
    done <<<"$REPOS"
}

pruefe_lokal() {   # $1 = Verzeichnis, $2 = repo
    ( cd "$1"
      [ -f scripts/docs/gen-readme-tabellen.py ] && python3 scripts/docs/gen-readme-tabellen.py >&2
      mvn -q -B -DskipTests -Dmaven.build.cache.enabled=false test-compile >&2 )
}

# Ein Release ist erst fertig, wenn der push-Lauf des Commits, aus dem er gebaut wurde, gruen
# ist UND das Blatt-Artefakt im Paket-Repo liegt (Karte 1340, Ablauf 3: "Pipeline bis success
# abwarten"). $1 repo  $2 Klonverzeichnis  $3 Version  $4 Blatt-Artefakt (leer = keines)
release_fertig() {
    local repo="$1" dir="$2" ver="$3" blatt="${4:-}" sha rc=0
    sha="$(release_quelle "$dir" "$ver")" || die "$repo: kein Commit \"Release version $ver\" auf master"
    warte_auf_pipeline "$repo" "$sha" 120 || rc=$?
    case "$rc" in
        0) ;;
        3) die "$repo: Lauf zu Release $ver nicht pruefbar (Woodpecker-API)" ;;
        *) die "$repo: Release $ver nicht fertig (Lauf zu ${sha:0:8} nicht gruen)" ;;
    esac
    if [ -n "$blatt" ]; then
        warte_auf_artefakt ch/plaintext "$blatt" "$ver" jar || die "$repo: $blatt $ver nicht im Paket-Repo"
    fi
}

# Ein Maven-Repo patchen, PR eroeffnen, im Modus "ausrollen" mergen und Release/Rollout abwarten.
# Gibt auf stdout die Version aus, der die Kinder folgen sollen: die neue Release-Version, oder —
# wenn das Repo ein Blatt-Artefakt hat und nichts zu patchen ist — die zuletzt veroeffentlichte.
# Letzteres macht den Lauf WIEDERAUFSETZBAR: ist root schon gepatcht und released (etwa weil ein
# frueherer Lauf danach abbrach), wird root nicht erneut angefasst, und die Kinder bekommen die
# vorhandene Version, sobald deren Release fertig ist.
maven_repo() {   # $1 repo  $2 versions-url  $3 ausrollen  $4 root-version  $5 app-version  $6 Blatt
    local repo="$1" url="$2" roll="$3" root="${4:-}" app="${5:-}" blatt="${6:-}" dir aenderungen owasp pr nr alt neu betreff
    dir="$(klone "$repo")"
    local optionen=()
    [ -n "$root" ] && optionen+=(--parent "$root")
    [ -n "$app" ] && optionen+=(--app "$app")
    aenderungen="$("$HIER/maven-patch.sh" "$dir" "${optionen[@]}")" || die "$repo: maven-patch.sh rot"
    owasp="$("$HIER/owasp-tote-suppressionen.sh" "$dir")" || die "$repo: OWASP-Pruefung (test-compile + dependency:list) rot"
    if git -C "$dir" diff --quiet; then
        if [ -z "$blatt" ]; then bericht "$repo: nichts zu patchen"; return 0; fi
        neu="$(release_version "$dir")"
        [ -n "$neu" ] || die "$repo: nichts zu patchen und kein Release auf master gefunden"
        release_fertig "$repo" "$dir" "$neu" "$blatt"
        bericht "$repo: nichts zu patchen, Release $neu ist fertig — die Kinder folgen $neu"
        echo "$neu"; return 0
    fi
    pruefe_lokal "$dir" "$repo" || die "$repo: test-compile rot, kein PR"
    betreff="chore(deps): Wochenpatch $WP_DATUM"
    # [skip ci] NUR im Squash-Betreff (merge_betreff), NIE in Commit-Nachricht oder PR-Titel: Woodpecker
    # nimmt bei PR-Ereignissen den PR-Titel als Nachricht, GitHub die Commit-Nachricht. Mit dem Marker
    # dort lief auf iot#261 keine CI, und warte_auf_pruefungen haette 120 min gewartet (Lauf 10/#12).
    merge_betreff="$betreff"
    if [ "$roll" = nein ]; then merge_betreff="$betreff [skip ci]"; fi
    if [ "$MODUS" = trocken ]; then
        bericht "$repo: wuerde PR \"$betreff\" eroeffnen, Merge-Betreff \"$merge_betreff\", test-compile gruen"
        bericht "$(sed 's/^/  /' <<<"$aenderungen")"
        [ -z "$owasp" ] || bericht "  OWASP entfernt: $(tr '\n' ' ' <<<"$owasp")"
        bericht "  fremde offene PRs: $(fremde_pr_liste "$repo" | wc -l), letztes Release: $(release_version "$dir")${url:+, live: $(curl -fsS -m 15 -A curl/8.0 "$url" 2>/dev/null | head -c 40 || echo '?')}"
        if [ "$roll" = nein ]; then bericht "  ausrollen: Squash-Merge mit [skip ci], KEIN Rollout"
        else bericht "  ausrollen: Squash-Merge, Release abwarten${url:+, Rollout ueber $url belegen}"; fi
        return 0
    fi
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

    warte_auf_pruefungen "$repo" "$nr" 120 || { pruefungen_befund "$repo" "$nr"; die "$repo: Pruefungen von PR #$nr nicht gruen, Lauf endet hier"; }
    autobumps_schliessen "$repo"   # der root-Release kann inzwischen einen neuen Auto-Bump eroeffnet haben
    pruefe_fremde "$repo" "kein Merge (PR #$nr bleibt offen)"
    warte_auf_deploy_ruhe 60 || die "$repo: Deploy-Lage unklar oder belegt, kein Merge"
    alt="$(release_version "$dir")"
    gh pr merge "$nr" -R "$WP_ORG/$repo" --squash --delete-branch --subject "$merge_betreff (#$nr)" >&2
    if [ "$roll" = nein ]; then bericht "$repo: gemergt ohne Rollout ([skip ci])"; return 0; fi
    for _ in $(seq 1 60); do
        neu="$(release_version "$dir")"; [ -n "$neu" ] && [ "$neu" != "$alt" ] && break; sleep "${WP_TAKT:-30}"
    done
    [ -n "$neu" ] && [ "$neu" != "$alt" ] || die "$repo: kein Release-Commit nach dem Merge"
    release_fertig "$repo" "$dir" "$neu" "$blatt"
    if [ -n "$url" ]; then warte_auf_rollout "$url" "$neu" || die "$repo: $neu nicht live"; fi
    bericht "$repo: $alt -> $neu${url:+ (live belegt)}"
    echo "$neu"
}

projectmind() {
    local dir nr bot
    dir="$(klone projectmind)"
    "$HIER/projectmind-patch.sh" "$dir" >/dev/null || die "projectmind: Pruefungen rot"
    if git -C "$dir" diff --quiet; then bericht "projectmind: nichts zu patchen"; return 0; fi
    if [ "$MODUS" = trocken ]; then
        bericht "projectmind: wuerde PR eroeffnen, Pruefungen gruen — $(git -C "$dir" diff --stat | tail -1)"
        bericht "  ausrollen: Squash-Merge, release.yml bump=patch, Cargo.lock auf den Release-PR, Tag"
        return 0
    fi
    git -C "$dir" add Cargo.lock app/package.json app/pnpm-lock.yaml
    git -C "$dir" commit -q -m "chore(deps): Wochenpatch $WP_DATUM (cargo update, pnpm update)"
    git -C "$dir" push -q -u origin "$WP_ZWEIG"
    nr="$(gh pr create -R "$WP_ORG/projectmind" --head "$WP_ZWEIG" --title "chore(deps): Wochenpatch $WP_DATUM" --body "Automatischer Wochenpatch (Karte 1340)." | sed 's|.*/||')"
    bericht "projectmind: PR #$nr"
    [ "$MODUS" = ausrollen ] || return 0
    warte_auf_pruefungen projectmind "$nr" 60 || { pruefungen_befund projectmind "$nr"; die "projectmind: PR #$nr nicht gruen"; }
    pruefe_fremde projectmind "kein Merge (PR #$nr bleibt offen)"
    gh pr merge "$nr" -R "$WP_ORG/projectmind" --squash --delete-branch >&2
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
    warte_auf_pruefungen projectmind "$nr" 60 || { pruefungen_befund projectmind "$nr"; die "projectmind: Release-PR #$nr nicht gruen"; }
    gh pr merge "$nr" -R "$WP_ORG/projectmind" --squash --delete-branch >&2
    git -C "$dir" fetch -q origin master
    git -C "$dir" tag -a "${bot#release/}" origin/master -m "ProjectMind ${bot#release/} (Wochenpatch $WP_DATUM)"
    git -C "$dir" push -q origin "${bot#release/}"
    bericht "projectmind: ${bot#release/} getaggt, Release-Build laeuft"
}

# Pushover nimmt hoechstens 1024 Zeichen; der Bericht eines vollen Laufs ist laenger. Deshalb steht
# der Abbruchgrund und was liegengeblieben ist VORN, der Rest wird gekuerzt (voller Bericht im Log).
# Der Versand selbst wird belegt (Karte 1419): Ergebnis und Rueckgabewert ins Log, ein fehlendes
# Skript oder Token ist ein Fehler, kein stilles Ueberspringen — der Job endet dann rot.
melden() {
    local status="$1" text rc=0 aus
    if [ "$MODUS" = trocken ] || [ "${WP_PUSHOVER:-ja}" = nein ]; then return 0; fi
    local skript="${WP_PUSHOVER_SKRIPT:-$HIER/../pushover}"
    [ -x "$skript" ] || { log "FEHLER Pushover: Skript $skript fehlt, nichts gemeldet"; return 1; }
    if [ -z "${PUSHOVER_APP_TOKEN:-}" ] || [ -z "${PUSHOVER_USER_KEY:-}" ]; then
        log "FEHLER Pushover: PUSHOVER_APP_TOKEN oder PUSHOVER_USER_KEY fehlt, nichts gemeldet"; return 1
    fi
    text="$( { grep -E '^(ABBRUCH|Liegengeblieben):' "$WP_BERICHT" || true; grep -v -E '^(ABBRUCH|Liegengeblieben):' "$WP_BERICHT" || true; } )"
    if [ "${#text}" -gt 1000 ]; then text="${text:0:960}
… gekuerzt, voller Bericht im Woodpecker-Log"; fi
    aus="$("$skript" -t "Wochenpatch $WP_DATUM: $status" ${CI_PIPELINE_URL:+-u "$CI_PIPELINE_URL" -U "Woodpecker-Lauf"} "$text" 2>&1)" || rc=$?
    if [ "$rc" = 0 ]; then log "Pushover gesendet ($status, ${#text} Zeichen)${aus:+: $aus}"
    else log "FEHLER Pushover: rc=$rc ${aus}"; fi
    return "$rc"
}
# EXIT statt ERR: `die` endet mit exit 1, und ein exit loest ERR nicht aus — die Abbruchmeldung
# waere sonst genau in den Faellen ausgeblieben, fuer die sie da ist.
ende() {
    local rc=$? mrc=0
    if [ "$rc" != 0 ]; then
        [ -z "${OFFEN:-}" ] || bericht "Liegengeblieben:${OFFEN}"
        melden ABGEBROCHEN || mrc=$?
    elif [ "$TEIL" != maven ]; then melden fertig || mrc=$?; fi
    cat "$WP_BERICHT" >&2
    # Ein gelungener Lauf ohne Meldung soll im Woodpecker rot erscheinen, sonst merkt es niemand.
    if [ "$rc" = 0 ] && [ "$mrc" != 0 ]; then exit 4; fi
}
trap ende EXIT

if [ "$MODUS" = trocken ] && [ "$TEIL" != projectmind ]; then
    rc=0; deploy_laeuft_nicht || rc=$?
    case "$rc" in 0) bericht "Deploy-Lage: kein offener Lauf auf master" ;;
                  1) bericht "Deploy-Lage: es laeuft gerade ein Deploy (ausrollen wuerde warten)" ;;
                  *) bericht "Deploy-Lage: NICHT pruefbar (ausrollen wuerde vor dem ersten Merge abbrechen)" ;; esac
fi

ROOT_NEU=""; APP_NEU=""; OFFEN=""
if [ "$TEIL" != projectmind ]; then
    # Was bei einem Abbruch liegenbleibt: das Repo, an dem es scheitert, und alle danach.
    OFFEN="$(awk -F'|' 'NF > 1 { printf " %s", $1 }' <<<"$REPOS")"
    vorpruefung
    # Ein Kind zeigt erst auf eine Version, wenn release_fertig sie belegt hat (Lauf gruen + Blatt-Jar).
    while IFS='|' read -r repo url roll blatt; do
        [ -n "$repo" ] || continue
        case "$repo" in
            plaintext-root)  ROOT_NEU="$(maven_repo "$repo" "$url" "$roll" "" "" "$blatt")" ;;
            plaintext-app)   APP_NEU="$(maven_repo "$repo" "$url" "$roll" "$ROOT_NEU" "" "$blatt")" ;;
            plaintext-guild) maven_repo "$repo" "$url" "$roll" "$ROOT_NEU" "$APP_NEU" "$blatt" >/dev/null ;;
            *)               maven_repo "$repo" "$url" "$roll" "$ROOT_NEU" "" "$blatt" >/dev/null ;;
        esac
        OFFEN="${OFFEN# "$repo"}"
    done <<<"$REPOS"
fi
if [ "$TEIL" != maven ]; then projectmind; fi
