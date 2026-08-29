#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Build Logic Library (shared via plaintext-scripts)
#  Business logic for build, release, deploy, and version mgmt.
#  Sourced by: build
#  Requires: tui-common.sh, build-conf.txt loaded
#  Expects: SCRIPT_DIR set, cwd = SCRIPT_DIR
# ═══════════════════════════════════════════════════════════════

# ── Load project configuration ───────────────────────────────
# Source common functions for config loading
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/common-functions.sh"

if ! load_build_conf "$SCRIPT_DIR"; then
    echo "ERROR: build-conf.txt not found (checked plaintext-config and $SCRIPT_DIR)" >&2
    exit 1
fi

# Validate required config
: "${IMAGE_NAME:?IMAGE_NAME must be set in build-conf.txt}"
: "${WEBAPP_MODULE:?WEBAPP_MODULE must be set in build-conf.txt}"
: "${TUI_TITLE:?TUI_TITLE must be set in build-conf.txt}"

# Auto-detect container runtime.
# - In CI (self-hosted runner): docker bevorzugt — der Runner-Container hat
#   /var/run/docker.sock vom Host gemountet, podman hätte keine machine.
# - macOS dev: /opt/homebrew/bin/podman (typische Setup).
# - Sonstige Linux: podman falls da, sonst docker.
if [ "${CI:-}" = "true" ] && command -v docker &>/dev/null; then
    CONTAINER_CLI="docker"
elif [ -f "/opt/homebrew/bin/podman" ]; then
    CONTAINER_CLI="/opt/homebrew/bin/podman"
elif command -v podman &>/dev/null; then
    CONTAINER_CLI="podman"
elif command -v docker &>/dev/null; then
    CONTAINER_CLI="docker"
else
    echo "Error: Neither podman nor docker found!"
    exit 1
fi

# Ensure podman machine is running (macOS only)
ensure_podman_running() {
    if [[ "$CONTAINER_CLI" != *"podman"* ]]; then
        return 0
    fi
    if $CONTAINER_CLI info &>/dev/null; then
        return 0
    fi
    echo -e "${YELLOW}Podman machine not running, starting...${NC}"
    podman machine start 2>/dev/null
    if ! $CONTAINER_CLI info &>/dev/null; then
        echo -e "${RED}✗ Failed to start Podman machine${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ Podman machine started${NC}"
}

# Auto-detect NAS IP: Use NAT IP when running on Zorin VM
if [ "$(hostname)" = "plaintext-zorin" ]; then
    NAS_HOST="192.100.0.1"
else
    NAS_HOST="192.168.1.224"
fi

REGISTRY="${NAS_HOST}:6666"
DEPLOY_SERVER="mad@${NAS_HOST}"

# ── Read versions from pom.xml (no more version.txt / versionRelease.txt) ──
get_pom_version() {
    mvn help:evaluate -Dexpression=project.version -q -DforceStdout 2>/dev/null || \
        grep -m1 '<version>' pom.xml | sed 's/.*<version>//;s/<\/version>.*//' | tr -d ' '
}

get_release_version() {
    # Latest git tag that looks like a version number
    git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || echo "0.0.0"
}

# ── Staging-Jar-Race-Haerte (Defense-in-Depth, #16/fleetd) ────
# jars/staging/app.jar ist eine GETEILTE Datei pro App (kein Lock, keine PID/Run-Eindeutigkeit) --
# ueberlappende stage_jar_to_nas()-Laeufe koennten sie theoretisch mit dem Jar eines ANDEREN Laufs
# ueberschreiben, bevor der Slot-Copy passiert. Verifiziert die Implementation-Version im Manifest
# des Staging-Jars gegen die erwartete Version, UNMITTELBAR VOR dem Slot-Copy -- faengt genau dieses
# Fenster ab. Fail-open bei fehlendem `unzip`/leerem Manifest-Eintrag (kein Primaerschutz, soll
# Deploys nicht blockieren, wenn das Tool fehlt); faengt aber einen klaren Mismatch hart ab.
verify_staging_jar_version() {
    local EXPECTED_VERSION="$1"
    if [ "${EXPECTED_VERSION}" == "latest" ] || [ -z "${EXPECTED_VERSION}" ]; then
        # SNAPSHOT-Builds: Docker-Tag/Aufrufkontext liefert kein festes Ziel zum Vergleichen
        # (analog SKIP_VERSION_MATCH in check_container_health) -- nichts zu verifizieren.
        return 0
    fi
    local STAGED_VERSION
    STAGED_VERSION=$(ssh "${DEPLOY_SERVER}" \
        "unzip -p ${DEPLOY_PATH}/jars/staging/app.jar META-INF/MANIFEST.MF 2>/dev/null" \
        | grep '^Implementation-Version:' | sed 's/^Implementation-Version: *//' | tr -d '\r\n')
    if [ -z "${STAGED_VERSION}" ]; then
        echo -e "${YELLOW}⚠ Staging-Jar-Versionscheck übersprungen (unzip fehlt oder Manifest ohne Implementation-Version) — kein Primärschutz, fahre fort.${NC}"
        return 0
    fi
    if [ "${STAGED_VERSION}" != "${EXPECTED_VERSION}" ]; then
        echo -e "${RED}✗ Staging-Jar-Version stimmt nicht überein: erwartet '${EXPECTED_VERSION}', gefunden '${STAGED_VERSION}'.${NC}"
        echo -e "${RED}  Vermutlich hat ein ANDERER, überlappender Deploy-Lauf jars/staging/app.jar überschrieben (Race Condition).${NC}"
        echo -e "${RED}  Abbruch vor dem Slot-Copy -- bitte stage_jar_to_nas für diesen Lauf erneut ausführen, sobald der andere Lauf fertig ist.${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ Staging-Jar-Version verifiziert (${STAGED_VERSION})${NC}"
    return 0
}
DEPLOY_PATH="${DEPLOY_PATH:-/volume1/docker/${IMAGE_NAME}}"
COMPOSE_FILE="docker-compose.yaml"

# ── M3: Jar im Volume (statt Image pro Version) ──────────────
# Opt-in pro App via Marker-Datei `.m3-jar-volume` im App-Repo. Ist sie vorhanden, wird beim
# Deploy NICHT mehr ein per-Version-Image gebaut + per save/load transferiert, sondern nur das
# Spring-Boot-Exec-Jar in ein gemountetes Volume kopiert (gemeinsames `plaintext-runtime:jre25`-
# Image). Spart docker build + save/load + den Image-Tag-Bump pro Release. cwd ist beim Sourcen
# das App-Repo-Root (build-Wrapper macht `cd` davor).
JAR_VOLUME_DEPLOY="${JAR_VOLUME_DEPLOY:-false}"
if [ -f ".m3-jar-volume" ]; then
    JAR_VOLUME_DEPLOY=true
fi

# ── Legacy color aliases (used by business logic echo statements) ─
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── Business Logic Functions ─────────────────────────────────

# Function to show usage
show_usage() {
    echo -e "${BLUE}Usage:${NC}"
    echo ""
    echo -e "${BLUE}Direct menu options (numbers):${NC}"
    echo -e "  ${GREEN}./build 0${NC}                  - Build + Run locally (no Docker)"
    echo -e "  ${GREEN}./build 1${NC}                  - Build with Maven (SNAPSHOT)"
    echo -e "  ${GREEN}./build 2${NC}                  - Major release (X.0.0)"
    echo -e "  ${GREEN}./build 3${NC}                  - Minor release (x.X.0)"
    echo -e "  ${GREEN}./build 4${NC}                  - Patch release (x.x.X)"
    echo -e "  ${GREEN}./build 5${NC}                  - Minor release + deploy to DEV (with health check)"
    echo -e "  ${GREEN}./build 6${NC}                  - Deploy last release to PROD (with health check)"
    echo ""
    echo -e "  ${GREEN}./build s${NC}                  - Run SonarQube analysis"
    echo ""
    echo -e "${BLUE}Multi-command execution:${NC}"
    echo -e "  ${GREEN}./build 56${NC}                 - Execute 5, then 6 (stops on first failure)"
    echo -e "  ${GREEN}./build 56s${NC}                - Release + Deploy DEV + PROD + SonarQube"
    echo -e "  ${GREEN}./build 356${NC}                - Execute 3, then 5, then 6"
    echo ""
    echo -e "${BLUE}Legacy commands (still supported):${NC}"
    echo -e "  ${GREEN}./build build${NC}              - Build with Maven (SNAPSHOT)"
    echo -e "  ${GREEN}./build release [1|2|3] [deploy]${NC} - Release build"
    echo -e "    ${YELLOW}1${NC} = Major version (X.0.0)"
    echo -e "    ${YELLOW}2${NC} = Minor version (default) (x.X.0)"
    echo -e "    ${YELLOW}3${NC} = Patch version (x.x.X)"
    echo -e "  ${GREEN}./build deploy-prod${NC}        - Deploy last release to PROD"
    echo ""
    echo -e "${BLUE}Lokal-Release (zweiter Weg neben CI/CD; Wrapper muss ihn verdrahten, plaintext-app: ./build 8):${NC}"
    echo -e "  ${GREEN}./build local-release [1|2|3] [prod|dev-prod]${NC}"
    echo -e "    Release + Tag + Push (Commit mit [skip-ci]) + Build + Blue-Green-Deploy von dieser Maschine"
    echo -e "    ${YELLOW}prod${NC} = direkt PROD (Default), ${YELLOW}dev-prod${NC} = erst DEV, dann PROD"
    echo -e "    Nur Vorflug: ${YELLOW}LOKAL_RELEASE_NUR_VORFLUG=true${NC}   CI-Sperre uebergehen: ${YELLOW}LOKAL_RELEASE_IGNORIERE_CI=true${NC}"
}

# NAS remote temp path for image transfer
NAS_REMOTE_TEMP="/volume1/docker/temp"

# Function to push image to NAS
push_to_registry() {
    local IMAGE_TAG="$1"
    local FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

    local TEMP_FILE="/tmp/${IMAGE_NAME}-${IMAGE_TAG}.tar.gz"

    # Save image to tarball
    echo -e "${BLUE}Saving image to ${TEMP_FILE}...${NC}"
    $CONTAINER_CLI save "${FULL_IMAGE}" | gzip > "${TEMP_FILE}"

    # Ensure NAS is reachable (stops Twingate if needed)
    if ! ensure_nas_reachable; then
        echo -e "${RED}✗ Cannot transfer image - NAS not reachable${NC}"
        rm -f "${TEMP_FILE}"
        return 1
    fi

    # Transfer to NAS via SSH pipe (works reliably on macOS and Linux)
    echo -e "${BLUE}Transferring to NAS via SSH...${NC}"
    ssh "${DEPLOY_SERVER}" "mkdir -p ${NAS_REMOTE_TEMP}"
    cat "${TEMP_FILE}" | ssh "${DEPLOY_SERVER}" "cat > ${NAS_REMOTE_TEMP}/${IMAGE_NAME}-${IMAGE_TAG}.tar.gz"

    # Load on NAS Docker and tag as IMAGE_NAME:TAG (matching docker-compose.yaml)
    echo -e "${BLUE}Loading image on NAS...${NC}"
    ssh "${DEPLOY_SERVER}" "
        LOADED=\$(sudo docker load -i ${NAS_REMOTE_TEMP}/${IMAGE_NAME}-${IMAGE_TAG}.tar.gz | grep 'Loaded image:' | sed 's/Loaded image: //') && \
        sudo docker tag \"\$LOADED\" ${IMAGE_NAME}:${IMAGE_TAG} && \
        echo \"Tagged \$LOADED as ${IMAGE_NAME}:${IMAGE_TAG}\" && \
        rm ${NAS_REMOTE_TEMP}/${IMAGE_NAME}-${IMAGE_TAG}.tar.gz
    "

    # Cleanup local temp file
    rm -f "${TEMP_FILE}"

    echo -e "${GREEN}Image loaded on NAS successfully${NC}"
}

# M3 (Jar im Volume): überträgt das gebaute Spring-Boot-Exec-Jar in den Staging-Pfad auf dem NAS
# (Ersatz für docker build + push_to_registry). deploy_blue_green kopiert es von dort pro Slot in
# das slot-eigene Volume. Übertragung atomar via .tmp + mv; chmod 644 für Container-User (UID 1000).
stage_jar_to_nas() {
    local JAR
    # Spring-Boot-Exec-Jar finden: entweder per -exec-Classifier (app/root/iot/schuetu) ODER
    # in-place repackaged (fwtool: Haupt-Jar mit <name>.jar.original-Geschwister).
    JAR=$(find "$PWD" -path '*/target/*-exec.jar' -type f 2>/dev/null | head -1)
    if [ -z "$JAR" ]; then
        local c
        for c in $(find "$PWD" -path '*/target/*.jar' -type f ! -name '*.original' ! -name '*-sources.jar' ! -name '*-javadoc.jar' 2>/dev/null); do
            if [ -f "${c}.original" ]; then JAR="$c"; break; fi
        done
    fi
    if [ -z "$JAR" ]; then
        # Build-Cache-Restore-Fall: das Fat-Jar liegt OHNE -exec-Suffix und OHNE .original-
        # Geschwister im target/ (Restore materialisiert es unter dem Haupt-Artefakt-Namen).
        # Groesstes Jar nehmen, aber NUR wenn es nachweislich ein Boot-Jar ist (BOOT-INF im
        # Zip-Verzeichnis; grep -a liest den unkomprimierten Eintragsnamen aus dem Archiv).
        local c
        for c in $(find "$PWD" -path '*/target/*.jar' -type f ! -name '*-sources.jar' ! -name '*-javadoc.jar' 2>/dev/null | xargs -r ls -S 2>/dev/null); do
            if grep -aq 'BOOT-INF/' "$c" 2>/dev/null; then JAR="$c"; break; fi
        done
        [ -n "$JAR" ] && echo -e "${BLUE}M3: Boot-Jar ohne -exec-Suffix erkannt (Cache-Restore): $(basename "$JAR")${NC}"
    fi
    if [ -z "$JAR" ] || [ ! -f "$JAR" ]; then
        echo -e "${RED}✗ M3: Kein Spring-Boot-Exec-Jar gefunden (Maven-Build gelaufen?)${NC}"
        return 1
    fi
    echo -e "${BLUE}M3: Staging Jar → NAS: $(basename "$JAR") ($(du -h "$JAR" | cut -f1))${NC}"
    if ! ensure_nas_reachable; then
        echo -e "${RED}✗ M3: NAS nicht erreichbar${NC}"
        return 1
    fi
    local STAGING="${DEPLOY_PATH}/jars/staging"
    # Tmp-Name PID+Zeitstempel-eindeutig (statt einem fixen "app.jar.tmp"): zwei ueberlappende
    # stage_jar_to_nas()-Laeufe fuer dieselbe App wuerden sich sonst denselben Tmp-Pfad teilen und
    # sich gegenseitig ueberschreiben/verstuemmeln (Race Condition, #16/fleetd Haertung).
    local TMP_NAME="app.jar.tmp.$$.$(date +%s 2>/dev/null || echo 0)"
    # Massnahme 2: die Kopie selbst unter Lock — zwei Laeufe ueberschreiben sich sonst gegenseitig.
    deploy_lock_acquire "staging" || return 1
    ssh "${DEPLOY_SERVER}" "mkdir -p ${STAGING}"
    if ! cat "${JAR}" | ssh "${DEPLOY_SERVER}" "cat > ${STAGING}/${TMP_NAME} && chmod 644 ${STAGING}/${TMP_NAME} && mv -f ${STAGING}/${TMP_NAME} ${STAGING}/app.jar"; then
        ssh "${DEPLOY_SERVER}" "rm -f ${STAGING}/${TMP_NAME}" 2>/dev/null
        echo -e "${RED}✗ M3: Jar-Transfer auf NAS fehlgeschlagen${NC}"
        deploy_lock_release "staging"
        return 1
    fi
    deploy_lock_release "staging"
    echo -e "${GREEN}✓ M3: Jar im Staging (${STAGING}/app.jar)${NC}"
}

# Function to create backup of prod database (PostgreSQL via SSH on NAS)
backup_prod_db() {
    local REMOTE_BACKUP_DIR="${DEPLOY_PATH}/backups"
    local BACKUP_NAME="backup-$(date +%y-%m-%d_%H-%M).sql.gz"
    local REMOTE_BACKUP_PATH="${REMOTE_BACKUP_DIR}/${BACKUP_NAME}"
    local _DB_CONTAINER="${DB_CONTAINER_PREFIX:-${IMAGE_NAME}}-db-prod"
    local _DB_NAME="${DB_NAME:-${IMAGE_NAME}}"
    # Karte 955: wie viele Deploy-Sicherungen aufbewahrt werden. Ohne Aufbewahrung waechst der
    # Ordner unbegrenzt -- app allein macht ~29 Deploys/Woche a 1,59 GB.
    local _KEEP="${BACKUP_KEEP_DEPLOY:-5}"
    # Karte 955: ein leeres gzip ist 20 Byte gross. Alles darunter ist keine Sicherung.
    local _MIN_BYTE="${BACKUP_MIN_BYTE:-1024}"

    echo -e "${BLUE}=== Creating database backup ===${NC}" >&2
    echo -e "${BLUE}Backup location: ${GREEN}${REMOTE_BACKUP_PATH}${NC}" >&2

    # Karte 955: KEINE Pipe mehr. Frueher stand hier "pg_dump ... | gzip > datei"; danach ist
    # $? der Status des LETZTEN Glieds, also von gzip -- und gzip gelingt auch dann, wenn
    # pg_dump nichts liefert (es schreibt ein leeres Archiv von 20 Byte und meldet 0).
    # Zusammen mit einem falschen DB_CONTAINER_PREFIX ergab das 611 leere Sicherungen, jede
    # als "Database backup created" gemeldet, fuenf Monate lang unbemerkt.
    # "pg_dump -Z" komprimiert selbst; damit ist $? wieder der Status von docker exec.
    # Massnahme 3: -Z 1 statt 9 (2 GB Mail-Anhaenge: Minuten statt Sekunden Unterschied, Datei
    # kaum groesser) und --lock-wait-timeout: haengt ein ALTER TABLE eines anderen Laufs, bricht
    # der Dump nach 30 s sauber ab statt beide zu blockieren.
    # Am lebenden System belegt: falscher Container -> alt rc=0/20 Byte, neu rc=1/0 Byte.
    ssh ${DEPLOY_SERVER} "mkdir -p '${REMOTE_BACKUP_DIR}' && \
        sudo docker exec ${_DB_CONTAINER} pg_dump -U plaintext -Z ${BACKUP_GZIP_LEVEL:-1} --lock-wait-timeout=${BACKUP_LOCK_WAIT:-30s} ${_DB_NAME} > '${REMOTE_BACKUP_PATH}'"
    local _RC=$?

    if [ ${_RC} -ne 0 ]; then
        echo -e "${RED}✗ Database backup failed (pg_dump/docker exec rc=${_RC})!${NC}" >&2
        ssh ${DEPLOY_SERVER} "rm -f '${REMOTE_BACKUP_PATH}'" >/dev/null 2>&1
        return 1
    fi

    # Karte 955: zweite, unabhaengige Wache. Ein Aufruf, der 0 meldet, aber nichts geschrieben
    # hat, ist trotzdem keine Sicherung -- und genau darauf greift restore_prod_db() zurueck.
    local _SIZE
    _SIZE=$(ssh ${DEPLOY_SERVER} "stat -c %s '${REMOTE_BACKUP_PATH}' 2>/dev/null || stat -f %z '${REMOTE_BACKUP_PATH}' 2>/dev/null || echo 0")
    if [ "${_SIZE:-0}" -lt "${_MIN_BYTE}" ]; then
        echo -e "${RED}✗ Database backup is empty (${_SIZE:-0} bytes, expected >= ${_MIN_BYTE})!${NC}" >&2
        echo -e "${RED}   Container: ${_DB_CONTAINER}, database: ${_DB_NAME}${NC}" >&2
        ssh ${DEPLOY_SERVER} "rm -f '${REMOTE_BACKUP_PATH}'" >/dev/null 2>&1
        return 1
    fi

    # Karte 955: Aufbewahrung. Die BACKUP_KEEP_*-Regeln des Sicherungs-Containers
    # (prodrigestivill/postgres-backup-local) gelten NUR fuer dessen eigenen scheduled/-Baum --
    # hier raeumt sonst niemand auf.
    ssh ${DEPLOY_SERVER} "ls -1t '${REMOTE_BACKUP_DIR}'/backup-*.sql.gz 2>/dev/null | tail -n +$((_KEEP + 1)) | xargs -r rm -f" >/dev/null 2>&1

    echo -e "${GREEN}✓ Database backup created: ${BACKUP_NAME} (${_SIZE} bytes)${NC}" >&2
    echo "${REMOTE_BACKUP_PATH}"
    return 0
}

# Function to restore database from backup (PostgreSQL via SSH on NAS)
restore_prod_db() {
    local BACKUP_PATH=$1

    echo -e "${BLUE}=== Restoring database from backup ===${NC}"
    echo -e "${BLUE}Backup file: ${GREEN}${BACKUP_PATH}${NC}"

    # Check remote backup file exists
    if ! ssh ${DEPLOY_SERVER} "[ -f '${BACKUP_PATH}' ]"; then
        echo -e "${RED}Error: Backup file not found on NAS: ${BACKUP_PATH}${NC}"
        return 1
    fi

    # Restore: drop and recreate database, then load backup
    echo -e "${BLUE}Restoring database from backup...${NC}"
    local _DB_CONTAINER="${DB_CONTAINER_PREFIX:-${IMAGE_NAME}}-db-prod"
    local _DB_NAME="${DB_NAME:-${IMAGE_NAME}}"
    ssh ${DEPLOY_SERVER} "sudo docker exec ${_DB_CONTAINER} psql -U plaintext -d postgres -c 'DROP DATABASE IF EXISTS ${_DB_NAME};' && \
        sudo docker exec ${_DB_CONTAINER} psql -U plaintext -d postgres -c 'CREATE DATABASE ${_DB_NAME} OWNER plaintext;' && \
        gunzip -c '${BACKUP_PATH}' | sudo docker exec -i ${_DB_CONTAINER} psql -U plaintext ${_DB_NAME}"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Database restored from backup${NC}"
        return 0
    else
        echo -e "${RED}✗ Database restore failed!${NC}"
        return 1
    fi
}

# ── Deploy-Lock auf dem NAS (Massnahme 2, 29.08.2026) ──────────────────────────────────
# Zwei Rollouts desselben Projekts (zwei lokale Sessions, lokal + CI) teilen sich Staging-Jar,
# Slots, nginx-Upstream und DB. Die CI hat dafuer ihre Concurrency-Gruppe — die kennt aber den
# lokalen Lauf nicht. Der Lock lebt deshalb auf dem NAS, wo sich ALLE Laeufe treffen:
# ein Verzeichnis (mkdir ist atomar) mit Besitzer-Datei "token zeit version". Verwaiste Locks
# (abgebrochener Lauf) werden nach DEPLOY_LOCK_STALE Sekunden uebernommen.
DEPLOY_LOCK_WAIT="${DEPLOY_LOCK_WAIT:-1800}"      # max. Wartezeit auf einen fremden Lauf (s)
DEPLOY_LOCK_STALE="${DEPLOY_LOCK_STALE:-3600}"    # aelter als das = verwaist
DEPLOY_LOCK_TOKEN="$(hostname -s 2>/dev/null || hostname)-$$-$(date +%s)"
DEPLOY_LOCK_HELD=""

deploy_lock_pfad() { echo "${DEPLOY_PATH}/.deploy-lock-${1}"; }

deploy_lock_acquire() {
    local ENV_NAME="$1"
    local LOCK
    LOCK=$(deploy_lock_pfad "$ENV_NAME")
    case " ${DEPLOY_LOCK_HELD} " in *" ${ENV_NAME} "*) return 0 ;; esac
    local INFO="${DEPLOY_LOCK_TOKEN} $(date +%s) ${NEW_VERSION:-${RELEASE_VERSION:-?}}${CI:+ ci}"
    local GEWARTET=0
    while true; do
        if ssh ${DEPLOY_SERVER} "mkdir '${LOCK}' 2>/dev/null && echo '${INFO}' > '${LOCK}/owner'" 2>/dev/null; then
            DEPLOY_LOCK_HELD="${DEPLOY_LOCK_HELD} ${ENV_NAME}"
            echo -e "${GREEN}✓ Deploy-Lock ${ENV_NAME} gesetzt (${DEPLOY_LOCK_TOKEN})${NC}"
            return 0
        fi
        local OWNER
        OWNER=$(ssh ${DEPLOY_SERVER} "cat '${LOCK}/owner' 2>/dev/null" 2>/dev/null)
        local TS
        TS=$(printf '%s' "$OWNER" | awk '{print $2}' | tr -dc '0-9')
        if [ -n "$TS" ] && [ $(( $(date +%s) - TS )) -gt "$DEPLOY_LOCK_STALE" ]; then
            echo -e "${YELLOW}⚠ Verwaister Deploy-Lock ${ENV_NAME} (${OWNER}) — wird uebernommen.${NC}"
            ssh ${DEPLOY_SERVER} "rm -rf '${LOCK}'" 2>/dev/null
            continue
        fi
        if [ -z "$OWNER" ] && ! ssh ${DEPLOY_SERVER} "[ -d '${LOCK}' ]" 2>/dev/null; then
            # mkdir scheiterte, aber es gibt keinen Lock: SSH/Rechte-Problem, nicht Konkurrenz.
            echo -e "${RED}✗ Deploy-Lock ${ENV_NAME} kann nicht angelegt werden (${LOCK}) — SSH/Rechte pruefen.${NC}"
            return 1
        fi
        if [ "$GEWARTET" -ge "$DEPLOY_LOCK_WAIT" ]; then
            echo -e "${RED}✗ Deploy-Lock ${ENV_NAME} seit ${GEWARTET}s belegt von: ${OWNER} — Abbruch.${NC}"
            echo -e "${YELLOW}  Haengt der andere Lauf wirklich? Dann: ssh ${DEPLOY_SERVER} rm -rf '${LOCK}'${NC}"
            return 1
        fi
        if [ "$GEWARTET" -eq 0 ]; then
            echo -e "${YELLOW}⏳ Deploy-Lock ${ENV_NAME} belegt von: ${OWNER} — warte (max ${DEPLOY_LOCK_WAIT}s)...${NC}"
        fi
        sleep 15
        GEWARTET=$((GEWARTET + 15))
    done
}

deploy_lock_release() {
    local ENV_NAME="$1"
    local LOCK
    LOCK=$(deploy_lock_pfad "$ENV_NAME")
    case " ${DEPLOY_LOCK_HELD} " in *" ${ENV_NAME} "*) ;; *) return 0 ;; esac
    # Nur den eigenen Lock loesen (Token in der Besitzer-Datei).
    if ssh ${DEPLOY_SERVER} "grep -q '^${DEPLOY_LOCK_TOKEN} ' '${LOCK}/owner' 2>/dev/null && rm -rf '${LOCK}'" 2>/dev/null; then
        echo -e "${GREEN}✓ Deploy-Lock ${ENV_NAME} freigegeben${NC}"
    fi
    local REST="" W
    for W in ${DEPLOY_LOCK_HELD}; do [ "$W" != "$ENV_NAME" ] && REST="${REST} ${W}"; done
    DEPLOY_LOCK_HELD="$REST"
}

# ── Deploy-Backup nur bei anstehender Migration (Massnahme 3, 29.08.2026) ────────────────
# Der pg_dump vor jedem PROD-Deploy (2 GB, davon 1.4 GB Mail-Anhaenge) kostete 3-4 Minuten und
# blockierte parallel laufende Flyway-ALTERs. Ohne neue Migration im Release kann nichts
# unumkehrbares passieren — dann reicht die Nightly-Sicherung des Backup-Containers.
# Hoechste Flyway-Version im Staging-Jar (inkl. der Modul-Jars unter BOOT-INF/lib).
jar_max_migration() {
    ssh ${DEPLOY_SERVER} "T=\$(mktemp -d) && cd \"\$T\" && unzip -q -o '${DEPLOY_PATH}/jars/staging/app.jar' 'BOOT-INF/lib/plaintext-*.jar' 'BOOT-INF/classes/db/migration/*' >/dev/null 2>&1; { ls BOOT-INF/classes/db/migration/ 2>/dev/null; for j in BOOT-INF/lib/plaintext-*.jar; do [ -f \"\$j\" ] && unzip -Z1 \"\$j\" 'db/migration/*' 2>/dev/null; done; } | sed -nE 's#.*V([0-9]+)__.*#\\1#p' | sort -n | tail -1; cd /; rm -rf \"\$T\"" 2>/dev/null | tr -dc '0-9'
}
# Hoechste numerische Flyway-Version in der DB des Environments.
db_max_migration() {
    local ENV_NAME="$1"
    local _DB_CONTAINER="${DB_CONTAINER_PREFIX:-${IMAGE_NAME}}-db-${ENV_NAME}"
    local _DB_NAME="${DB_NAME:-${IMAGE_NAME}}"
    ssh -o ConnectTimeout=8 ${DEPLOY_SERVER} \
        "sudo docker exec ${_DB_CONTAINER} psql -U plaintext -d ${_DB_NAME} -tAc \"SELECT COALESCE(MAX(version::numeric),0) FROM flyway_schema_history WHERE version ~ '^[0-9]+\$'\" 2>/dev/null" \
        2>/dev/null | tr -dc '0-9'
}
# 0 = Backup machen, 1 = entfaellt. Fail-safe: wenn der Stand nicht ermittelbar ist, wird gesichert.
backup_noetig() {
    if [ "${BACKUP_ALWAYS:-false}" == "true" ]; then
        echo -e "${BLUE}Deploy-Backup erzwungen (BACKUP_ALWAYS=true).${NC}"
        return 0
    fi
    if [ "${JAR_VOLUME_DEPLOY:-false}" != "true" ]; then
        return 0
    fi
    local J D
    J=$(jar_max_migration)
    D=$(db_max_migration "prod")
    if [ -z "$J" ] || [ -z "$D" ]; then
        echo -e "${YELLOW}⚠ Migrationsstand nicht ermittelbar (Jar='${J}', DB='${D}') — Deploy-Backup wird gemacht.${NC}"
        return 0
    fi
    if [ "$J" -gt "$D" ]; then
        echo -e "${BLUE}Neue Migration im Release (Jar V${J} > DB V${D}) — Deploy-Backup wird erstellt.${NC}"
        return 0
    fi
    echo -e "${BLUE}Keine neue Migration (Jar V${J}, DB V${D}) — Deploy-Backup entfaellt (erzwingen: BACKUP_ALWAYS=true).${NC}"
    return 1
}
backup_bezeichnung() {
    if [ -n "${BACKUP_PATH:-}" ]; then basename "${BACKUP_PATH}"; else echo "keines (keine Migration — Nightly-Sicherung des Backup-Containers)"; fi
}

# ── Blue-Green Configuration ─────────────────────────────────
BG_NGINX_CONF_DIR="${DEPLOY_PATH}/nginx/conf.d"
BG_NGINX_TEMPLATES_DIR="${DEPLOY_PATH}/nginx/templates"
BG_NGINX_CONTAINER="${IMAGE_NAME}-nginx"

# Karte 379 (PROD-Ausfall 31.07.2026, 45 Min 502): nginx loest Upstream-Namen NUR beim Start bzw.
# beim Reload auf und haelt die IP danach fest. Ein `docker compose up -d --force-recreate` gibt dem
# Container eine NEUE IP -- nginx verbindet weiter zur alten und liefert 502, obwohl der Container
# gesund ist und der DNS korrekt aufloest. `switch_active` reloadet nur beim SLOT-WECHSEL; wird
# derselbe Slot neu erstellt, bleibt die upstream.conf gleich und der Reload unterblieb bisher.
#
# Daher: nach JEDEM Recreate reloaden, unabhaengig davon ob der Slot wechselt.
# Bewusst tolerant (return 0): ein fehlender/abwesender Stack-nginx darf kein Deploy abbrechen.
# `nginx -t` vorweg, damit ein Reload nicht auf einer kaputten Config ausgefuehrt wird.
nginx_reload_after_recreate() {
    local REASON="${1:-recreate}"
    if [ -z "${BG_NGINX_CONTAINER}" ]; then
        return 0
    fi
    echo -e "${BLUE}nginx-Reload nach ${REASON} (${BG_NGINX_CONTAINER}) - Upstream-IPs neu aufloesen...${NC}"
    if ! ssh ${DEPLOY_SERVER} "sudo docker ps --format '{{.Names}}' | grep -qx '${BG_NGINX_CONTAINER}'"; then
        echo -e "${YELLOW}  ${BG_NGINX_CONTAINER} laeuft nicht - Reload uebersprungen${NC}"
        return 0
    fi
    if ! ssh ${DEPLOY_SERVER} "sudo docker exec ${BG_NGINX_CONTAINER} nginx -t"; then
        echo -e "${YELLOW}  nginx -t fehlgeschlagen - KEIN Reload (Config waere kaputt)${NC}"
        return 0
    fi
    if ssh ${DEPLOY_SERVER} "sudo docker exec ${BG_NGINX_CONTAINER} nginx -s reload"; then
        echo -e "${GREEN}✓ nginx-Reload ok${NC}"
    else
        echo -e "${YELLOW}  nginx -s reload fehlgeschlagen - bitte pruefen${NC}"
    fi
    return 0
}

# Get the currently active slot for an environment ("blue" or "green")
get_active_slot() {
    local ENV_NAME="$1"
    ssh ${DEPLOY_SERVER} "cat ${DEPLOY_PATH}/active-${ENV_NAME} 2>/dev/null || echo 'blue'"
}

# Get the inactive slot for an environment
get_inactive_slot() {
    local ENV_NAME="$1"
    local ACTIVE
    ACTIVE=$(get_active_slot "$ENV_NAME")
    if [ "$ACTIVE" == "blue" ]; then
        echo "green"
    else
        echo "blue"
    fi
}

# ── Migrations-Guard (Blue-Green-Rollback vs. bereits migrierte geteilte DB) ──────────────────
# Problem: deploy_blue_green fährt beim Boot des neuen Slots die Flyway-Migrationen gegen die GETEILTE
# Prod-DB, BEVOR der externe Healthcheck läuft. Schlägt dieser fehl, würde ein blinder "Instant
# Rollback" auf den ALTEN Container laufen, dessen Code das NEUE Schema evtl. nicht versteht.
# Lösung: höchsten flyway installed_rank als Marker beim ERFOLGREICHEN Deploy-Abschluss festhalten
# (NICHT in switch_active — der schaltet den Traffic bereits vor dem externen Check auf den neuen Slot;
# ein Marker dort wäre beim Rollback schon = aktueller Rank und der Guard wirkungslos). Vor einem
# automatischen Rollback aktuellen Rank gegen den Marker prüfen. Fail-open by default.

# Höchster flyway installed_rank der Ziel-DB (leer bei jedem Fehler; kurzer SSH-Timeout, der
# Rollback-Pfad muss schnell bleiben). Nur Ziffern.
get_db_migration_rank() {
    local ENV_NAME="$1"
    local _DB_CONTAINER="${DB_CONTAINER_PREFIX:-${IMAGE_NAME}}-db-${ENV_NAME}"
    local _DB_NAME="${DB_NAME:-${IMAGE_NAME}}"
    ssh -o ConnectTimeout=8 ${DEPLOY_SERVER} \
        "sudo docker exec ${_DB_CONTAINER} psql -U plaintext -d ${_DB_NAME} -tAc 'SELECT COALESCE(MAX(installed_rank),0) FROM flyway_schema_history' 2>/dev/null" \
        2>/dev/null | tr -dc '0-9'
}

# Marker (letzter bekannt-guter Rank) neben active-<env> auf der NAS lesen. Nur Ziffern.
get_migration_marker() {
    local ENV_NAME="$1"
    ssh -o ConnectTimeout=8 ${DEPLOY_SERVER} "cat ${DEPLOY_PATH}/migver-${ENV_NAME} 2>/dev/null" 2>/dev/null | tr -dc '0-9'
}

# Marker = aktueller DB-Rank festschreiben. Best effort: darf einen erfolgreichen Deploy NIE failen.
write_migration_marker() {
    local ENV_NAME="$1"
    local RANK
    RANK=$(get_db_migration_rank "$ENV_NAME")
    if [ -n "$RANK" ]; then
        ssh ${DEPLOY_SERVER} "echo '${RANK}' > ${DEPLOY_PATH}/migver-${ENV_NAME}" 2>/dev/null \
            && echo -e "${BLUE}Migration marker (${ENV_NAME}) = rank ${RANK}${NC}" >&2 \
            || echo -e "${YELLOW}⚠ Migration marker (${ENV_NAME}) konnte nicht geschrieben werden (ignoriert).${NC}" >&2
    fi
}

# Rückgabe: 0 = Rollback sicher, 1 = UNSICHER (seit letztem Deploy sind Migrationen gelaufen).
# Fail-open: Marker/DB nicht ermittelbar -> 0 (Warnung), ausser MIGRATION_GUARD_STRICT=true -> 1.
assert_rollback_safe() {
    local ENV_NAME="$1"
    # Ops-Kill-Switch: altes Blind-Rollback-Verhalten erzwingen, falls der Guard je stört.
    if [ "${MIGRATION_GUARD_DISABLE:-false}" == "true" ]; then
        echo -e "${YELLOW}⚠ Migrations-Guard deaktiviert (MIGRATION_GUARD_DISABLE=true).${NC}" >&2
        return 0
    fi
    local MARKER CURRENT
    MARKER=$(get_migration_marker "$ENV_NAME")
    CURRENT=$(get_db_migration_rank "$ENV_NAME")
    if [ -z "$MARKER" ] || [ -z "$CURRENT" ]; then
        echo -e "${YELLOW}⚠ Migrations-Guard (${ENV_NAME}): Marker/DB-Stand nicht ermittelbar (Marker='${MARKER}', DB='${CURRENT}').${NC}" >&2
        if [ "${MIGRATION_GUARD_STRICT:-false}" == "true" ]; then
            echo -e "${RED}   MIGRATION_GUARD_STRICT=true -> Rollback wird blockiert.${NC}" >&2
            return 1
        fi
        echo -e "${YELLOW}   Fail-open: Rollback läuft wie bisher.${NC}" >&2
        return 0
    fi
    if [ "$CURRENT" -gt "$MARKER" ]; then
        return 1
    fi
    return 0
}

# Switch nginx upstream to the specified slot
switch_active() {
    local ENV_NAME="$1"
    local NEW_COLOR="$2"
    local ZIEL_CONTAINER="${IMAGE_NAME}-${ENV_NAME}-${NEW_COLOR}"

    echo -e "${BLUE}Switching ${ENV_NAME} to ${NEW_COLOR}...${NC}"

    # Karte 632: Ersatz für einen Schutz, der mit der Resolver-Umstellung wegfällt.
    #
    # Der `nginx -t` weiter unten wirkte bisher nebenbei als Rollback-Schutz: bei einem
    # `upstream{}`-Block löst nginx den Zielnamen beim Test auf und bricht ab, wenn der Slot nicht
    # läuft. Seit die Upstreams als Variable + `resolver` konfiguriert sind (Karte 379 für app,
    # Karte 632 für guild/iot/schuetu/root/fwtool), findet beim Test keine Auflösung mehr statt.
    # Gemessen am 09.08.2026 gegen einen gestoppten Slot:
    #     upstream{}   -> "host not found in upstream ..."  / "test failed"
    #     map+resolver -> "syntax is ok" / "test is successful"
    # Ein Umschalten auf einen gestoppten Slot würde also stillschweigend gelingen und die
    # Umgebung vom Netz nehmen -- genau der Fall, den der alte Test verhindert hat.
    #
    # Ersatz: vorher fragen, ob der Zielcontainer läuft. Das ist strenger als der alte Test, der
    # nur die Namensauflösung prüfte und einen laufenden, aber toten Container durchgelassen hätte.
    # Notausgang für einen erzwungenen Rollback: SWITCH_FORCE=true.
    if [ "${SWITCH_FORCE:-false}" != "true" ]; then
        if ! ssh ${DEPLOY_SERVER} "sudo docker inspect -f '{{.State.Running}}' ${ZIEL_CONTAINER} 2>/dev/null" | grep -qx "true"; then
            echo -e "${RED}✗ Zielcontainer ${ZIEL_CONTAINER} läuft nicht - Umschalten abgebrochen.${NC}"
            echo -e "${YELLOW}  Der Traffic bleibt, wo er ist. Slot zuerst starten, dann erneut umschalten.${NC}"
            echo -e "${YELLOW}  (Bewusst erzwingen: SWITCH_FORCE=true switch_active ${ENV_NAME} ${NEW_COLOR})${NC}"
            return 1
        fi
    else
        echo -e "${YELLOW}⚠ SWITCH_FORCE=true - Slot-Prüfung übersprungen.${NC}"
    fi

    # Defensiv: vorherige upstream-Config sichern, neue einspielen und mit `nginx -t` PRÜFEN, BEVOR
    # Marker gesetzt + reloaded wird. Ist die neue Config syntaktisch kaputt, stellen wir die
    # vorherige wieder her und ändern weder Marker noch laufende nginx-Config. So bleibt nie eine
    # kaputte conf liegen (die sonst den nächsten Reload/Reboot des GESAMTEN nginx inkl. PROD
    # verhindern würde).
    #
    # NICHT mehr abgedeckt (Karte 632): ein Ziel-Slot, der nicht läuft. Seit der Umstellung auf
    # `resolver` + Variable löst nginx beim Test nicht mehr auf -- dafür ist die Slot-Prüfung oben
    # zuständig, nicht dieser `nginx -t`.
    ssh ${DEPLOY_SERVER} "
        cp ${BG_NGINX_CONF_DIR}/${ENV_NAME}-upstream.conf /tmp/${ENV_NAME}-upstream.conf.${DEPLOY_LOCK_TOKEN}.bak 2>/dev/null || true
        cp ${BG_NGINX_TEMPLATES_DIR}/${ENV_NAME}-${NEW_COLOR}.conf ${BG_NGINX_CONF_DIR}/${ENV_NAME}-upstream.conf || exit 1
        if sudo docker exec ${BG_NGINX_CONTAINER} nginx -t; then
            echo '${NEW_COLOR}' > ${DEPLOY_PATH}/active-${ENV_NAME}
            sudo docker exec ${BG_NGINX_CONTAINER} nginx -s reload
        else
            echo 'nginx -t fehlgeschlagen - stelle vorherige upstream-Config wieder her, Marker unveraendert'
            cp /tmp/${ENV_NAME}-upstream.conf.${DEPLOY_LOCK_TOKEN}.bak ${BG_NGINX_CONF_DIR}/${ENV_NAME}-upstream.conf 2>/dev/null || true
            exit 1
        fi
    "

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Switched ${ENV_NAME} to ${NEW_COLOR}${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to switch ${ENV_NAME} to ${NEW_COLOR}${NC}"
        return 1
    fi
}

# Deutet die letzten Container-Logs eines gescheiterten Starts und sagt, WAS zu tun ist.
#
# Anlass (Karte 398): Am 01.08.2026 starb plaintext-schuetu-prod-blue mit
# "PROD: JWT private key muss aus dem Vault-Item kommen". Das las sich wie eine fehlende
# Konfiguration — sie war aber vorhanden. Zwei Zeilen darueber stand die Ursache:
# Vaultwarden hatte den Login mit HTTP 429 abgewiesen, der VaultwardenClient faehrt
# "fail-safe fort" und liefert kein Secret, und der JwtTokenService kann danach nicht mehr
# unterscheiden zwischen "Item existiert nicht" und "Vault war gerade nicht erreichbar".
# Die Karte trug deshalb tagelang den falschen Titel. Diese Funktion trennt die beiden Faelle.
diagnose_startfehler() {
    local LOGS="$1"

    if echo "$LOGS" | grep -q "HTTP 429"; then
        echo -e "${YELLOW}⚠ Diagnose: Der Start scheiterte an einer TRANSIENTEN Vault-Stoerung, nicht an${NC}"
        echo -e "${YELLOW}  fehlender Konfiguration. Im Log steht ein HTTP 429 (Rate-Limit) von Vaultwarden;${NC}"
        echo -e "${YELLOW}  der Secret-Client faehrt danach ohne Secret fort, und die JWT-Meldung ist nur die${NC}"
        echo -e "${YELLOW}  Folgewirkung. Vault-Item und Referenz sind vermutlich in Ordnung.${NC}"
        echo -e "${YELLOW}  Zu tun: pruefen, welcher Dienst Vaultwarden mit Logins flutet (typisch: ein${NC}"
        echo -e "${YELLOW}  Container im Crashloop), das abstellen und den Deploy wiederholen.${NC}"
        return 0
    fi

    if echo "$LOGS" | grep -q "muss aus dem Vault-Item"; then
        echo -e "${YELLOW}⚠ Diagnose: Der JWT-Schluessel liess sich nicht aus dem Vault-Item lesen, und im Log${NC}"
        echo -e "${YELLOW}  steht KEIN 429. Hier lohnt der Blick auf das Item selbst: existiert es, hat es das${NC}"
        echo -e "${YELLOW}  Feld 'private_key_pem', und zeigt PLAINTEXT_JWT_PRIVATE_KEY_VAULT_ITEM darauf?${NC}"
        return 0
    fi

    return 0
}

# Health check on a specific container via docker exec
check_container_health() {
    local CONTAINER_NAME="$1"
    local EXPECTED_VERSION="$2"
    # 600s (statt 300s): der app-PROD-Kaltstart auf dem NAS braucht unter Last >300s bis Actuator UP
    # (2026-07-02 zweimal in Folge: Container wurde Sekunden NACH dem 300s-Abbruch healthy, green blieb
    # aktiv und der neue Slot lief verwaist weiter). DEV bootet in <60s und ist davon unberührt; ein
    # echter Crash wird unten via RestartCount früh erkannt (kein sinnloses Auswarten des Timeouts).
    # Via HEALTHCHECK_MAX_WAIT überschreibbar.
    local MAX_WAIT="${3:-${HEALTHCHECK_MAX_WAIT:-600}}"
    local INTERVAL=5
    local ELAPSED=0

    # For SNAPSHOT builds the Docker tag is "latest" but the /nosec/version endpoint
    # returns the Maven version (e.g. "2.425.0-SNAPSHOT").  In that case we skip the
    # version string comparison and only verify health status.
    local SKIP_VERSION_MATCH=false
    if [ "$EXPECTED_VERSION" == "latest" ]; then
        SKIP_VERSION_MATCH=true
    fi

    echo -e "${BLUE}=== Health checking container: ${CONTAINER_NAME} ===${NC}"
    if [ "$SKIP_VERSION_MATCH" == "true" ]; then
        echo -e "${BLUE}Expected version: ${GREEN}any (snapshot / latest)${NC}"
    else
        echo -e "${BLUE}Expected version: ${GREEN}${EXPECTED_VERSION}${NC}"
    fi
    echo -e "${BLUE}Max wait: ${MAX_WAIT}s${NC}"

    while [ $ELAPSED -lt $MAX_WAIT ]; do
        echo -e "${YELLOW}Checking... (${ELAPSED}s / ${MAX_WAIT}s)${NC}"

        # Früh-Abbruch bei abgestürztem/crash-loopendem Container: nicht das ganze Fenster verwarten und
        # die Ursache (Logs) sofort zeigen, statt eines undurchsichtigen Healthcheck-Timeouts. Ein gesunder
        # Startup geht created->running (RestartCount 0); exited/dead oder RestartCount>=2 = Crash.
        local CSTATE
        CSTATE=$(ssh ${DEPLOY_SERVER} "sudo docker inspect -f '{{.State.Status}}:{{.RestartCount}}' ${CONTAINER_NAME} 2>/dev/null || echo 'unknown:0'")
        case "$CSTATE" in
            exited:*|dead:*|*:[2-9]|*:[1-9][0-9]*)
                echo -e "${RED}✗ Container ${CONTAINER_NAME} startet nicht (State ${CSTATE}) – Abbruch. Letzte Logs:${NC}"
                # 300 statt 60 Zeilen (Vorfall 21.08.2026): Der Fail-fast-Abbruch bei einer
                # unaufloesbaren vault:-Referenz druckt ZWEI ~30-zeilige Stacktraces NACH der
                # entscheidenden WARN-Zeile "... token-Endpoint HTTP 429 ...". Mit --tail 60
                # bestand der Dump nur aus den Stacktraces, der 429-Beweis lag oberhalb des
                # Fensters — HEALTHCHECK_SAH_429 blieb false und der Karte-422-Retry zuendete
                # nie (guild 1.372.0 und app-snapshot scheiterten genau daran). Gezeigt werden
                # weiterhin nur die letzten 60 Zeilen; Diagnose und 429-Erkennung lesen alle 300.
                local CRASH_LOGS
                CRASH_LOGS=$(ssh ${DEPLOY_SERVER} "sudo docker logs --tail 300 ${CONTAINER_NAME} 2>&1 | tail -300")
                echo "$CRASH_LOGS" | tail -60
                diagnose_startfehler "$CRASH_LOGS"
                # Fuer den Retry in deploy_to_slot: sichtbar machen, ob ein 429 im Spiel war.
                if echo "$CRASH_LOGS" | grep -q "HTTP 429"; then
                    HEALTHCHECK_SAH_429=true
                fi
                return 1 ;;
        esac

        local VERSION_RESPONSE
        VERSION_RESPONSE=$(ssh ${DEPLOY_SERVER} \
            "sudo docker exec ${CONTAINER_NAME} wget -qO- http://localhost:8080/nosec/version 2>/dev/null || echo ''")

        local VERSION_OK=false
        if [ "$SKIP_VERSION_MATCH" == "true" ]; then
            # For snapshot builds: accept any non-empty version response
            if [ -n "$VERSION_RESPONSE" ]; then
                VERSION_OK=true
            fi
        elif [ "$VERSION_RESPONSE" == "$EXPECTED_VERSION" ]; then
            VERSION_OK=true
        fi

        if [ "$VERSION_OK" == "true" ]; then
            local HEALTH_RESPONSE
            HEALTH_RESPONSE=$(ssh ${DEPLOY_SERVER} \
                "sudo docker exec ${CONTAINER_NAME} wget -qO- http://localhost:8080/actuator/health 2>/dev/null || echo ''")

            if echo "$HEALTH_RESPONSE" | grep -q '"status":"UP"'; then
                echo -e "${GREEN}✓ Health check passed! Version: ${VERSION_RESPONSE}, Status: UP${NC}"
                return 0
            else
                echo -e "${YELLOW}Version OK (${VERSION_RESPONSE}) but health not UP yet...${NC}"
            fi
        else
            if [ -n "$VERSION_RESPONSE" ]; then
                echo -e "${YELLOW}Version: '${VERSION_RESPONSE}' (expected '${EXPECTED_VERSION}')${NC}"
            else
                echo -e "${YELLOW}Container not responding yet...${NC}"
            fi
        fi

        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    # Zeitfenster ausgelaufen (Karte 422, Punkt 2): Bis hierher kam frueher nur die eine Zeile
    # "Health check failed after 600s" — und damit wusste niemand etwas. Genau in diesen Pfad
    # laeuft ein Container, der LANGSAM stirbt statt schnell: der Frueh-Abbruch oben greift nur
    # bei exited/dead oder RestartCount>=2, ein Container, der einfach nie UP meldet, bleibt
    # "running" und laeuft ins Timeout. Deshalb hier dieselben Logs und dieselbe Diagnose wie
    # im Crash-Pfad.
    echo -e "${RED}✗ Health check failed after ${MAX_WAIT}s! Letzte Logs:${NC}"
    # 300 Zeilen wie im Crash-Pfad: die 429-WARN-Zeile darf nicht oberhalb des Fensters liegen.
    local TIMEOUT_LOGS
    TIMEOUT_LOGS=$(ssh ${DEPLOY_SERVER} "sudo docker logs --tail 300 ${CONTAINER_NAME} 2>&1 | tail -300")
    echo "$TIMEOUT_LOGS" | tail -60
    diagnose_startfehler "$TIMEOUT_LOGS"
    # Fuer den Retry in deploy_to_slot: sichtbar machen, ob im Timeout-Pfad ein 429 stand.
    if echo "$TIMEOUT_LOGS" | grep -q "HTTP 429"; then
        HEALTHCHECK_SAH_429=true
    fi
    return 1
}

# Prueft VOR dem Start des neuen Slots, ob die Pflicht-Secrets vorhanden und aufloesbar sind.
#
# Anlass (Karte 398, Aufgabe 5): Ein nicht lesbarer JWT-Schluessel kostete am 01.08.2026 erst
# einen kompletten Release-Build (08:47) und dann 37s Healthcheck (08:51:47–08:52:24), bevor
# ueberhaupt jemand erfuhr, was fehlt. Diese Pruefung meldet dasselbe in Sekunden, bevor ein
# laufender Slot angefasst wird.
#
# BEWUSSTE GRENZE: Sie erkennt eine fehlende/leere Konfiguration und einen nicht erreichbaren
# Vaultwarden. Sie erkennt NICHT, ob Vaultwarden gerade mit HTTP 429 abriegelt — dafuer muesste
# sie sich einloggen, und genau dieser Login-Versuch wuerde selbst ins Rate-Limit einzahlen und
# die Lage verschlimmern. Fuer diesen Fall greift die Diagnose in diagnose_startfehler().
#
# Schlaegt die Pruefung selbst fehl (Config nicht lesbar), wird NICHT abgebrochen: eine
# Leitplanke, die Deploys aus eigenem Unvermoegen blockiert, ist schlimmer als keine.
preflight_secrets() {
    local COMPOSE_SERVICE="$1"

    # Ohne aktivierten Vault gibt es keine Pflicht-Secrets zu pruefen.
    local PFLICHT_VARS="${REQUIRED_SECRET_VARS:-PLAINTEXT_VAULT_EMAIL PLAINTEXT_VAULT_MASTER_PASSWORD PLAINTEXT_JWT_PRIVATE_KEY_VAULT_ITEM}"
    local VAULT_URL="${VAULT_HEALTH_URL:-https://vault.plaintext.ch/alive}"

    echo -e "${BLUE}Preflight: Pflicht-Secrets fuer ${COMPOSE_SERVICE}...${NC}"

    # Die Auswertung laeuft vollstaendig auf dem NAS und gibt nur Variablen-NAMEN zurueck.
    # Die Werte (u.a. das Vault-Master-Passwort) verlassen den Host nicht und landen nie im
    # CI-Log — deshalb hier kein "docker compose config" auf der Runner-Seite.
    local ERGEBNIS
    ERGEBNIS=$(ssh ${DEPLOY_SERVER} "DP='${DEPLOY_PATH}' SVC='${COMPOSE_SERVICE}' VARS='${PFLICHT_VARS}' bash -s" <<'REMOTE'
CFG=$(cd "$DP" 2>/dev/null && sudo docker compose config "$SVC" 2>/dev/null)
if [ -z "$CFG" ]; then echo "UNLESBAR"; exit 0; fi
if ! printf '%s\n' "$CFG" | grep -qE '^[[:space:]]+PLAINTEXT_VAULT_ENABLED:[[:space:]]*"?true"?[[:space:]]*$'; then
    echo "VAULT_AUS"; exit 0
fi
FEHLT=""
for v in $VARS; do
    printf '%s\n' "$CFG" | grep -qE "^[[:space:]]+$v:[[:space:]]*\"?[^[:space:]\"]" || FEHLT="$FEHLT $v"
done
echo "FEHLT:$FEHLT"
REMOTE
)

    case "$ERGEBNIS" in
        UNLESBAR)
            echo -e "${YELLOW}⚠ Preflight uebersprungen: 'docker compose config ${COMPOSE_SERVICE}' war nicht lesbar.${NC}"
            return 0 ;;
        VAULT_AUS)
            echo -e "${BLUE}  Vault fuer diesen Slot nicht aktiv — keine Pflicht-Secrets zu pruefen.${NC}"
            return 0 ;;
    esac

    local FEHLENDE="${ERGEBNIS#FEHLT:}"
    if [ -n "$(echo "$FEHLENDE" | tr -d '[:space:]')" ]; then
        echo -e "${RED}✗ Preflight: Pflicht-Variablen fehlen oder sind leer:${FEHLENDE}${NC}"
        echo -e "${RED}  Der Slot wuerde beim Start daran scheitern. Deploy abgebrochen, bevor ein${NC}"
        echo -e "${RED}  laufender Container angefasst wurde. Zu pruefen: env_file des Service${NC}"
        echo -e "${RED}  ${COMPOSE_SERVICE} in ${DEPLOY_PATH} (typisch: vault.env bzw. app.env).${NC}"
        return 1
    fi

    # Erreichbarkeit: /alive ist ein reiner Lebendcheck und zaehlt nicht ins Login-Rate-Limit.
    local VAULT_CODE
    VAULT_CODE=$(ssh ${DEPLOY_SERVER} "curl -s -o /dev/null -m 10 -w '%{http_code}' '${VAULT_URL}' 2>/dev/null || echo '000'")
    if [ "$VAULT_CODE" != "200" ]; then
        echo -e "${RED}✗ Preflight: Vaultwarden nicht erreichbar (${VAULT_URL} -> HTTP ${VAULT_CODE}).${NC}"
        echo -e "${RED}  Die Slots koennen ihre vault:-Referenzen dann nicht aufloesen. Deploy abgebrochen.${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Preflight: Pflicht-Secrets gesetzt, Vaultwarden erreichbar (HTTP 200).${NC}"
    return 0
}

# Stoppt den GESCHEITERTEN neuen Slot nach einem endgueltig fehlgeschlagenen Healthcheck.
#
# Warum (Vorfall 21.08.2026): Der frisch erzeugte Slot-Container hat "restart: always". Bleibt er
# nach dem Deploy-Abbruch stehen, crashloopt er unbegrenzt weiter — und jeder Boot macht einen
# frischen Vaultwarden-Login. Der Login-Rate-Limiter (Token-Bucket, ein Bucket fuer ALLE Clients,
# weil alle als dieselbe NAT-IP ankommen) wird dadurch dauerhaft leergehalten: Docker-Restart-
# Backoff pendelt sich bei ~1 Boot/Minute ein, exakt der Refill-Rate. Am 21.08. hielt der
# Flyway-Zombie von app-int-green den Bucket leer und liess den guild-Release-Deploy UND den
# naechsten app-Deploy mit HTTP 429 scheitern (Kettenreaktion wie am 01.08., Karte 395).
#
# Gefahrlos: Der Traffic wurde nie umgeschaltet, der gescheiterte Slot bedient nichts. Der
# naechste Deploy erzeugt den Container ohnehin per force-recreate neu.
stoppe_gescheiterten_slot() {
    local CONTAINER_NAME="$1"
    echo -e "${BLUE}Stoppe den gescheiterten Slot ${CONTAINER_NAME} (kein Zombie-Crashloop gegen Vaultwarden)...${NC}"
    ssh ${DEPLOY_SERVER} "sudo docker stop ${CONTAINER_NAME}" >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ ${CONTAINER_NAME} gestoppt${NC}"
}

# Deploy image to the inactive slot using blue-green strategy
deploy_blue_green() {
    local ENV_NAME="$1"
    local IMAGE_TAG="$2"

    local ACTIVE_SLOT
    ACTIVE_SLOT=$(get_active_slot "$ENV_NAME")
    local INACTIVE_SLOT
    INACTIVE_SLOT=$(get_inactive_slot "$ENV_NAME")
    local CONTAINER_NAME="${IMAGE_NAME}-${ENV_NAME}-${INACTIVE_SLOT}"
    # Massnahme 1 (PROD 502, 29.08.2026): die HIER ermittelten Slots sind fuer den Aufrufer die
    # Wahrheit. deploy_to_prod/deploy_to_dev hatten den aktiven Slot VOR Backup+Deploy gelesen und
    # ~15 Minuten spaeter gestoppt — bei zwei parallelen Laeufen war das der frisch umgeschaltete
    # Slot des anderen. Globals statt Rueckgabewert, weil die Funktion ihren Exit-Code braucht.
    BG_ALT_SLOT="$ACTIVE_SLOT"
    BG_NEU_SLOT="$INACTIVE_SLOT"

    # Detect compose service name: long (IMAGE_NAME-env-slot) or short (env-slot)
    local LONG_SVC="${IMAGE_NAME}-${ENV_NAME}-${INACTIVE_SLOT}"
    local SHORT_SVC="${ENV_NAME}-${INACTIVE_SLOT}"
    local COMPOSE_SERVICE
    COMPOSE_SERVICE=$(ssh ${DEPLOY_SERVER} "cd ${DEPLOY_PATH} && \
        if grep -qE '^\s+${LONG_SVC}:' ${COMPOSE_FILE} 2>/dev/null; then echo '${LONG_SVC}'; \
        elif grep -qE '^\s+${SHORT_SVC}:' ${COMPOSE_FILE} 2>/dev/null; then echo '${SHORT_SVC}'; \
        else echo ''; fi")

    if [ -z "$COMPOSE_SERVICE" ]; then
        echo -e "${RED}✗ Service not found in ${COMPOSE_FILE}: tried ${LONG_SVC} and ${SHORT_SVC}${NC}"
        return 1
    fi

    echo -e "${BLUE}=== Blue-Green Deploy: ${ENV_NAME} ===${NC}"
    echo -e "${BLUE}Active slot:   ${GREEN}${ACTIVE_SLOT}${NC}"
    echo -e "${BLUE}Deploying to:  ${GREEN}${INACTIVE_SLOT}${NC} (${CONTAINER_NAME})"
    echo -e "${BLUE}Image tag:     ${GREEN}${IMAGE_TAG}${NC}"

    # Karte 398: erst pruefen, dann den Slot anfassen — nicht umgekehrt.
    if ! preflight_secrets "$COMPOSE_SERVICE"; then
        return 1
    fi

    if [ "${JAR_VOLUME_DEPLOY}" == "true" ]; then
        # M3: Jar aus dem Staging in das slot-eigene Volume kopieren, dann Container neu erzeugen
        # (lädt das neue Jar). Image bleibt das stabile plaintext-runtime:jre25 (in der Compose).
        local SLOT_JAR_DIR="${DEPLOY_PATH}/jars/${ENV_NAME}-${INACTIVE_SLOT}"
        echo -e "${BLUE}M3: Jar → Slot ${ENV_NAME}-${INACTIVE_SLOT} (${SLOT_JAR_DIR}/app.jar)...${NC}"
        if ! ssh ${DEPLOY_SERVER} "test -f ${DEPLOY_PATH}/jars/staging/app.jar"; then
            echo -e "${RED}✗ M3: Kein Staging-Jar gefunden (stage_jar_to_nas gelaufen?)${NC}"
            return 1
        fi
        if ! verify_staging_jar_version "${IMAGE_TAG}"; then
            return 1
        fi
        ssh ${DEPLOY_SERVER} "mkdir -p ${SLOT_JAR_DIR} && \
            cp -f ${DEPLOY_PATH}/jars/staging/app.jar ${SLOT_JAR_DIR}/app.jar && \
            chmod 644 ${SLOT_JAR_DIR}/app.jar"
        echo -e "${BLUE}Recreating ${COMPOSE_SERVICE} (force) to load new jar...${NC}"
        ssh ${DEPLOY_SERVER} "cd ${DEPLOY_PATH} && \
            sudo docker compose up -d --no-deps --force-recreate ${COMPOSE_SERVICE}"
        # Karte 379: neuer Container == potenziell neue IP -> nginx muss neu aufloesen.
        nginx_reload_after_recreate "Recreate ${COMPOSE_SERVICE}"
    else
        # Klassisch: Image-Tag des inaktiven Slots in der Compose umbiegen + Container neu erzeugen
        echo -e "${BLUE}Updating image for ${COMPOSE_SERVICE}...${NC}"
        ssh ${DEPLOY_SERVER} "cd ${DEPLOY_PATH} && \
            sed -i.backup '/${COMPOSE_SERVICE}:/,/image:/ s|image: ${IMAGE_NAME}:.*|image: ${IMAGE_NAME}:${IMAGE_TAG}|' ${COMPOSE_FILE} && \
            mkdir -p backups && mv ${COMPOSE_FILE}.backup backups/docker-compose-\$(date +%y-%m-%d_%H-%M).yaml"

        # Recreate only the inactive container
        echo -e "${BLUE}Restarting ${COMPOSE_SERVICE} with new image...${NC}"
        ssh ${DEPLOY_SERVER} "cd ${DEPLOY_PATH} && \
            sudo docker compose up -d --no-deps --pull never ${COMPOSE_SERVICE}"
        # Karte 379: neuer Container == potenziell neue IP -> nginx muss neu aufloesen.
        nginx_reload_after_recreate "Recreate ${COMPOSE_SERVICE}"
    fi

    echo -e "${BLUE}Container status:${NC}"
    ssh ${DEPLOY_SERVER} "sudo docker ps | grep ${CONTAINER_NAME} || echo 'Container not running!'"

    # Health check on the inactive container
    HEALTHCHECK_SAH_429=false
    if ! check_container_health "$CONTAINER_NAME" "$IMAGE_TAG"; then
        # EIN Wiederholungsversuch — ausschliesslich bei nachgewiesenem HTTP 429 (Karte 422, Punkt 1).
        #
        # Warum ueberhaupt: Ein 429 von Vaultwarden ist per Definition transient (Karte 395). Der
        # Deploy scheitert heute endgueltig an einem Zustand, der Sekunden spaeter vorbei ist — und
        # der neue Slot laeuft dabei bereits mit dem richtigen Jar, es fehlt ihm nur das Secret.
        #
        # Warum so eng gefasst: Automatische Wiederholungen im PROD-Deploy verschleiern Fehler.
        # Deshalb GENAU EIN Versuch, NUR wenn "HTTP 429" nachweislich im Container-Log stand, mit
        # spuerbarem Abstand — und laut protokolliert. Ein stiller Retry waere schlimmer als keiner.
        #
        # Nicht gefaehrlich, weil hier nichts halb Ausgerolltes wiederholt wird: der Traffic liegt
        # unveraendert auf ${ACTIVE_SLOT}, umgeschaltet wird erst NACH bestandenem Healthcheck.
        # Wiederholt wird allein der Container-Start des inaktiven Slots.
        if [ "${HEALTHCHECK_SAH_429}" == "true" ] && [ "${DEPLOY_RETRY_ON_429:-true}" == "true" ]; then
            local RETRY_WAIT="${DEPLOY_RETRY_WAIT:-60}"
            echo -e "${YELLOW}⟳ RETRY (1 von 1): Im Log stand HTTP 429 — eine transiente Vault-Stoerung.${NC}"
            echo -e "${YELLOW}  Warte ${RETRY_WAIT}s und starte ${CONTAINER_NAME} genau EINMAL neu.${NC}"
            echo -e "${YELLOW}  Traffic liegt weiterhin auf ${ACTIVE_SLOT} — es wird nichts umgeschaltet.${NC}"
            echo -e "${YELLOW}  Abschaltbar mit DEPLOY_RETRY_ON_429=false.${NC}"
            sleep "$RETRY_WAIT"
            ssh ${DEPLOY_SERVER} "sudo docker restart ${CONTAINER_NAME}"
            # Neuer Container-Start == potenziell neue IP -> nginx muss neu aufloesen (Karte 379).
            nginx_reload_after_recreate "Retry ${COMPOSE_SERVICE}"
            HEALTHCHECK_SAH_429=false
            if check_container_health "$CONTAINER_NAME" "$IMAGE_TAG"; then
                echo -e "${GREEN}✓ Retry erfolgreich — der 429 war transient.${NC}"
            else
                echo -e "${RED}✗ Health check auch im Wiederholungsversuch fehlgeschlagen (${CONTAINER_NAME}).${NC}"
                echo -e "${YELLOW}Damit ist es KEINE voruebergehende Stoerung mehr — die Ursache steht in den Logs oben.${NC}"
                echo -e "${YELLOW}Active slot (${ACTIVE_SLOT}) remains unchanged. No traffic switched.${NC}"
                stoppe_gescheiterten_slot "$CONTAINER_NAME"
                return 1
            fi
        else
            echo -e "${RED}✗ Health check failed on ${CONTAINER_NAME}!${NC}"
            echo -e "${YELLOW}Active slot (${ACTIVE_SLOT}) remains unchanged. No traffic switched.${NC}"
            stoppe_gescheiterten_slot "$CONTAINER_NAME"
            return 1
        fi
    fi

    # Switch nginx to the new slot
    echo -e "${BLUE}Health check passed - switching traffic...${NC}"
    if ! switch_active "$ENV_NAME" "$INACTIVE_SLOT"; then
        echo -e "${RED}✗ Nginx switch failed! Traffic still on ${ACTIVE_SLOT}.${NC}"
        return 1
    fi

    # WICHTIG: Der alte Slot wird hier BEWUSST NICHT gestoppt. Er bleibt am Leben, bis der EXTERNE
    # Healthcheck (check_version in deploy_to_dev/deploy_to_prod) erfolgreich war. Schlägt dieser fehl,
    # kann der Rollback (switch_active zurück) auf einen noch laufenden Slot zeigen -> keine kaputte
    # nginx-Config. Das Stoppen des alten Slots übernimmt der Aufrufer via stop_slot(), entweder nach
    # erfolgreichem externem Check oder (ohne externen Check) direkt danach.
    echo -e "${BLUE}Old slot (${ACTIVE_SLOT}) stays alive until external health check confirms ${INACTIVE_SLOT}.${NC}"

    echo -e "${GREEN}=== Blue-Green switch complete: ${ENV_NAME} now on ${INACTIVE_SLOT} (${IMAGE_TAG}) ===${NC}"
    return 0
}

# Stoppt einen Slot (alten Container) eines Environments. Erkennt Lang-/Kurz-Service-Namen wie
# deploy_blue_green. Wird vom Aufrufer NACH erfolgreichem externem Healthcheck genutzt (s. o.).
# stop_slot ENV SLOT [NEUE_VERSION]
# Massnahme 1: zwei Sicherungen gegen das Stoppen des falschen Slots (PROD 502, 29.08.2026):
#   a) nie den Slot stoppen, der laut Marker gerade Traffic traegt (ein paralleler Lauf hat
#      inzwischen umgeschaltet);
#   b) mit NEUE_VERSION: nie einen Container stoppen, der bereits die neue Version meldet
#      (dann ist es der frisch deployte Slot, nicht der alte).
# Beim Rollback (fehlgeschlagener NEUER Slot stoppen) NEUE_VERSION weglassen.
stop_slot() {
    local ENV_NAME="$1"
    local SLOT="$2"
    local NEUE_VERSION="${3:-}"
    local AKTIV
    AKTIV=$(get_active_slot "$ENV_NAME")
    if [ -n "$AKTIV" ] && [ "$AKTIV" == "$SLOT" ]; then
        echo -e "${RED}✗ stop_slot ${ENV_NAME}-${SLOT} VERWEIGERT: dieser Slot ist laut Marker AKTIV (traegt Traffic).${NC}"
        echo -e "${YELLOW}  Vermutlich hat ein paralleler Deploy inzwischen umgeschaltet — der Slot bleibt laufen.${NC}"
        return 1
    fi
    if [ -n "$NEUE_VERSION" ] && [ "$NEUE_VERSION" != "latest" ]; then
        local LAEUFT
        LAEUFT=$(ssh ${DEPLOY_SERVER} "sudo docker exec ${IMAGE_NAME}-${ENV_NAME}-${SLOT} wget -qO- http://localhost:8080/nosec/version 2>/dev/null || echo ''" 2>/dev/null | tr -d '\r\n ')
        if [ -n "$LAEUFT" ] && [ "$LAEUFT" == "$NEUE_VERSION" ]; then
            echo -e "${RED}✗ stop_slot ${ENV_NAME}-${SLOT} VERWEIGERT: der Container meldet bereits die NEUE Version ${LAEUFT} — das ist kein alter Slot.${NC}"
            return 1
        fi
    fi
    local SVC
    SVC=$(ssh ${DEPLOY_SERVER} "cd ${DEPLOY_PATH} && \
        if grep -qE '^\s+${IMAGE_NAME}-${ENV_NAME}-${SLOT}:' ${COMPOSE_FILE} 2>/dev/null; then echo '${IMAGE_NAME}-${ENV_NAME}-${SLOT}'; \
        else echo '${ENV_NAME}-${SLOT}'; fi")
    echo -e "${BLUE}Stopping ${ENV_NAME}-${SLOT} slot (${SVC})...${NC}"
    ssh ${DEPLOY_SERVER} "cd ${DEPLOY_PATH} && sudo docker compose stop ${SVC}" 2>/dev/null || true
    echo -e "${GREEN}✓ Stopped ${ENV_NAME}-${SLOT}${NC}"
}

# One-time setup: deploy blue-green infrastructure to NAS
setup_blue_green() {
    echo -e "${BLUE}=== Setting up Blue-Green deployment on NAS ===${NC}"

    if ! ensure_nas_reachable; then
        echo -e "${RED}✗ Cannot reach NAS${NC}"
        return 1
    fi

    local DEPLOY_DIR
    DEPLOY_DIR=$(get_deploy_dir "$SCRIPT_DIR")
    if [[ -z "$DEPLOY_DIR" ]]; then
        echo -e "${RED}✗ Deploy directory not found (checked plaintext-config and $SCRIPT_DIR)${NC}"
        return 1
    fi

    # Create directories on NAS
    echo -e "${BLUE}Creating directory structure...${NC}"
    ssh ${DEPLOY_SERVER} "
        mkdir -p ${DEPLOY_PATH}/nginx/conf.d
        mkdir -p ${DEPLOY_PATH}/nginx/templates
        mkdir -p ${DEPLOY_PATH}/${IMAGE_NAME}-int-blue/logs
        mkdir -p ${DEPLOY_PATH}/${IMAGE_NAME}-int-green/logs
        mkdir -p ${DEPLOY_PATH}/${IMAGE_NAME}-prod-blue/logs
        mkdir -p ${DEPLOY_PATH}/${IMAGE_NAME}-prod-green/logs
        mkdir -p ${DEPLOY_PATH}/backups/scheduled
    "

    # Transfer nginx configs via SSH pipe (avoids scp permission issues)
    echo -e "${BLUE}Transferring nginx configuration...${NC}"
    cat "${DEPLOY_DIR}/nginx/nginx.conf" | ssh ${DEPLOY_SERVER} "cat > ${DEPLOY_PATH}/nginx/nginx.conf"
    cat "${DEPLOY_DIR}/nginx/templates/int-blue.conf" | ssh ${DEPLOY_SERVER} "cat > ${DEPLOY_PATH}/nginx/templates/int-blue.conf"
    cat "${DEPLOY_DIR}/nginx/templates/int-green.conf" | ssh ${DEPLOY_SERVER} "cat > ${DEPLOY_PATH}/nginx/templates/int-green.conf"
    cat "${DEPLOY_DIR}/nginx/templates/prod-blue.conf" | ssh ${DEPLOY_SERVER} "cat > ${DEPLOY_PATH}/nginx/templates/prod-blue.conf"
    cat "${DEPLOY_DIR}/nginx/templates/prod-green.conf" | ssh ${DEPLOY_SERVER} "cat > ${DEPLOY_PATH}/nginx/templates/prod-green.conf"

    # Set initial upstream configs (blue active)
    echo -e "${BLUE}Setting initial upstream configs (blue active)...${NC}"
    ssh ${DEPLOY_SERVER} "
        cp ${DEPLOY_PATH}/nginx/templates/int-blue.conf ${DEPLOY_PATH}/nginx/conf.d/int-upstream.conf
        cp ${DEPLOY_PATH}/nginx/templates/prod-blue.conf ${DEPLOY_PATH}/nginx/conf.d/prod-upstream.conf
        echo 'blue' > ${DEPLOY_PATH}/active-int
        echo 'blue' > ${DEPLOY_PATH}/active-prod
    "

    # Backup existing docker-compose.yaml if present
    echo -e "${BLUE}Backing up current docker-compose.yaml...${NC}"
    ssh ${DEPLOY_SERVER} "cd ${DEPLOY_PATH} && \
        [ -f ${COMPOSE_FILE} ] && cp ${COMPOSE_FILE} ${COMPOSE_FILE}.pre-bluegreen-\$(date +%y-%m-%d_%H-%M) || true"

    echo -e "${BLUE}Transferring new docker-compose.yaml...${NC}"
    cat "${DEPLOY_DIR}/docker-compose-bluegreen.yaml" | ssh ${DEPLOY_SERVER} "cat > ${DEPLOY_PATH}/${COMPOSE_FILE}"

    # Start new blue-green stack
    echo -e "${BLUE}Starting blue-green stack...${NC}"
    ssh ${DEPLOY_SERVER} "cd ${DEPLOY_PATH} && \
        sudo docker compose up -d --pull never --remove-orphans"

    echo -e "${BLUE}Waiting for containers to start (30s)...${NC}"
    sleep 30

    # Karte 379: der komplette Stack wurde neu erzeugt -> nginx-Reload erzwingen.
    nginx_reload_after_recreate "Stack-Setup"

    # Verify
    echo -e "${BLUE}Container status:${NC}"
    ssh ${DEPLOY_SERVER} "sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | grep -E '${IMAGE_NAME}'"

    echo ""
    echo -e "${GREEN}=== Blue-Green setup complete! ===${NC}"
    echo -e "${GREEN}INT:  blue active (port 1121)${NC}"
    echo -e "${GREEN}PROD: blue active (port 1122)${NC}"
    return 0
}

# ── Twingate helpers (macOS only) ─────────────────────────────

TWINGATE_WAS_STOPPED=false

# Check if Twingate is currently running
is_twingate_running() {
    [[ "$(uname)" == "Darwin" ]] && pgrep -x "Twingate" >/dev/null 2>&1
}

# Stop Twingate (returns 0 if it was running and got stopped)
stop_twingate() {
    if is_twingate_running; then
        echo -e "${YELLOW}Stopping Twingate (interferes with local network)...${NC}"
        osascript -e 'quit app "Twingate"' 2>/dev/null
        sleep 2
        if ! is_twingate_running; then
            echo -e "${GREEN}✓ Twingate stopped${NC}"
            TWINGATE_WAS_STOPPED=true
            return 0
        fi
        echo -e "${YELLOW}Twingate still running, trying kill...${NC}"
        pkill -x "Twingate" 2>/dev/null
        sleep 1
        TWINGATE_WAS_STOPPED=true
        return 0
    fi
    return 1
}

# Start Twingate (only if we stopped it)
restart_twingate_if_needed() {
    if [ "$TWINGATE_WAS_STOPPED" == "true" ]; then
        echo -e "${BLUE}Restarting Twingate...${NC}"
        if [[ "$(uname)" == "Darwin" ]]; then
            open -a "Twingate" 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Twingate restarted${NC}"
            else
                echo -e "${YELLOW}Could not restart Twingate automatically. Please start it manually.${NC}"
            fi
        fi
        TWINGATE_WAS_STOPPED=false
    fi
}

# Ensure NAS is reachable via SSH
# If NAS is not reachable and Twingate is running, stop Twingate and retry
ensure_nas_reachable() {
    echo -e "${BLUE}Checking NAS connectivity (${NAS_HOST})...${NC}"
    if ssh -o ConnectTimeout=10 "${DEPLOY_SERVER}" "echo ok" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ NAS reachable${NC}"
        return 0
    fi

    # NAS not reachable - try stopping Twingate if it might interfere
    if is_twingate_running; then
        echo -e "${YELLOW}NAS not reachable, stopping Twingate and retrying...${NC}"
        stop_twingate
        sleep 2
        if ssh -o ConnectTimeout=10 "${DEPLOY_SERVER}" "echo ok" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ NAS reachable (after stopping Twingate)${NC}"
            return 0
        fi
    fi

    echo -e "${RED}✗ Cannot reach NAS at ${NAS_HOST}${NC}"
    return 1
}

# Function to check version endpoint
# $3 = optionales Zeitbudget, $4 = optionaler Container-Name fuer die Logausgabe im Timeout-Pfad.
check_version() {
    local EXPECTED_VERSION=$1
    local VERSION_URL=${2:-"http://${NAS_HOST}:${DEV_PORT:-1121}/nosec/version"}
    # 120s reichen fuer dev und den blue-green-PROD-Pfad. Der Single-PROD-Deploy (fwtool) braucht
    # unter Last mehr: am 03.08. und 05.08.2026 scheiterte er zweimal identisch nach 120s mit
    # HTTP 000, obwohl das Jar korrekt lag -- der jeweilige Rerun war gruen, und selbst der
    # brauchte auf der ruhigeren Box noch 95-100s bis zur ersten 200-Antwort (Karte 555).
    # Via CHECK_VERSION_MAX_WAIT ueberschreibbar, wie HEALTHCHECK_MAX_WAIT im blue-green-Pfad.
    local MAX_WAIT="${3:-${CHECK_VERSION_MAX_WAIT:-120}}"
    local LOG_CONTAINER="${4:-}"
    local INTERVAL=5
    local ELAPSED=0

    # For SNAPSHOT builds the Docker tag is "latest" but the /nosec/version endpoint
    # returns the Maven version (e.g. "2.425.0-SNAPSHOT").  In that case we only
    # verify that the endpoint responds successfully, without matching the exact string.
    local SKIP_VERSION_MATCH=false
    if [ "$EXPECTED_VERSION" == "latest" ]; then
        SKIP_VERSION_MATCH=true
    fi

    echo -e "${BLUE}=== Checking version endpoint ===${NC}"
    echo -e "${BLUE}URL: ${VERSION_URL}${NC}"
    if [ "$SKIP_VERSION_MATCH" == "true" ]; then
        echo -e "${BLUE}Expected version: ${GREEN}any (snapshot / latest)${NC}"
    else
        echo -e "${BLUE}Expected version: ${GREEN}${EXPECTED_VERSION}${NC}"
    fi
    echo -e "${BLUE}Max wait time: ${MAX_WAIT} seconds${NC}"

    while [ $ELAPSED -lt $MAX_WAIT ]; do
        echo -e "${YELLOW}Checking version... (${ELAPSED}s / ${MAX_WAIT}s)${NC}"

        VERSION_RESPONSE=$(curl -s "$VERSION_URL" 2>/dev/null || echo "")
        # Nicht "|| echo 000": curl gibt im Fehlerfall selbst schon "000" aus, das echo haengte ein
        # zweites an -- im Log stand dann "HTTP status: 000000" (Karte 555, beim Testen aufgefallen).
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$VERSION_URL" 2>/dev/null) || HTTP_STATUS="000"

        if [ "$HTTP_STATUS" == "200" ]; then
            if [ "$SKIP_VERSION_MATCH" == "true" ]; then
                echo -e "${GREEN}✓ Version check passed! Deployed version: ${VERSION_RESPONSE}${NC}"
                return 0
            elif [ "$VERSION_RESPONSE" == "$EXPECTED_VERSION" ]; then
                echo -e "${GREEN}✓ Version check passed! Deployed version: ${VERSION_RESPONSE}${NC}"
                return 0
            else
                echo -e "${YELLOW}Version mismatch: expected '${EXPECTED_VERSION}', got '${VERSION_RESPONSE}'${NC}"
            fi
        else
            echo -e "${YELLOW}HTTP status: ${HTTP_STATUS}${NC}"
        fi

        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done

    echo -e "${RED}✗ Version check failed! Expected version '${EXPECTED_VERSION}' did not appear within ${MAX_WAIT} seconds${NC}"
    echo -e "${RED}Last response: ${VERSION_RESPONSE}${NC}"
    echo -e "${RED}Last HTTP status: ${HTTP_STATUS}${NC}"
    # Karte 555: "HTTP status: 000" allein sagt nicht, ob der Container noch startet oder in einer
    # Schleife stirbt -- beides sieht von aussen gleich aus. Dieselbe Selbstauskunft wie im
    # blue-green-Timeout-Pfad (Karte 422), sofern der Aufrufer den Container benennt.
    if [ -n "$LOG_CONTAINER" ]; then
        echo -e "${RED}Letzte Logs von ${LOG_CONTAINER}:${NC}"
        local TIMEOUT_LOGS
        TIMEOUT_LOGS=$(ssh ${DEPLOY_SERVER} "sudo docker logs --tail 60 ${LOG_CONTAINER} 2>&1 | tail -60")
        echo "$TIMEOUT_LOGS"
        diagnose_startfehler "$TIMEOUT_LOGS"
    fi
    return 1
}

# Function to deploy to dev server (blue-green)
deploy_to_dev() {
    local IMAGE_TAG=$1
    local WITH_HEALTH_CHECK=${2:-false}

    echo -e "${BLUE}=== Deploying to DEV Server (Blue-Green) ===${NC}"

    # Lokaler Lauf (nicht CI): ein gerade laufender CI-Rollout benutzt dieselben Slots und
    # dasselbe Staging-Jar — erst pruefen, dann anfassen. In der CI ist das die Concurrency-Gruppe.
    if [ "${CI:-}" != "true" ] && ! lokal_release_ci_frei "${RELEASE_BRANCH:-master}"; then
        return 1
    fi
    if ! ensure_nas_reachable; then
        echo -e "${RED}✗ Cannot deploy - NAS not reachable${NC}"
        return 1
    fi
    # Massnahme 2: Rollout unter dem NAS-Deploy-Lock (int), Freigabe auf jedem Pfad.
    deploy_lock_acquire "int" || return 1
    deploy_to_dev_gesperrt "$IMAGE_TAG" "$WITH_HEALTH_CHECK"
    local RC=$?
    deploy_lock_release "int"
    return $RC
}

deploy_to_dev_gesperrt() {
    local IMAGE_TAG=$1
    local WITH_HEALTH_CHECK=${2:-false}

    # Ensure NAS is reachable
    if ! ensure_nas_reachable; then
        echo -e "${RED}✗ Cannot deploy - NAS not reachable${NC}"
        return 1
    fi

    # Aktiven (alten) Slot VOR dem Deploy merken - er bleibt am Leben, bis der externe Check ok ist.
    local OLD_SLOT
    OLD_SLOT=$(get_active_slot "int")
    local NEW_SLOT
    if [ "$OLD_SLOT" == "blue" ]; then NEW_SLOT="green"; else NEW_SLOT="blue"; fi

    # Deploy to the inactive INT slot
    if ! deploy_blue_green "int" "$IMAGE_TAG"; then
        echo -e "${RED}=== DEV Blue-Green Deployment FAILED ===${NC}"
        return 1
    fi
    # Massnahme 1: ab hier gelten die Slots, die deploy_blue_green tatsaechlich benutzt hat.
    OLD_SLOT="${BG_ALT_SLOT:-$OLD_SLOT}"
    NEW_SLOT="${BG_NEU_SLOT:-$NEW_SLOT}"

    # Additional external health check via nginx port
    if [ "$WITH_HEALTH_CHECK" == "true" ]; then
        echo ""
        if ! check_version "$IMAGE_TAG"; then
            echo -e "${RED}=== DEV external health check FAILED ===${NC}"
            # Migrations-Guard (INT): kein blinder Rollback, wenn seit letztem Deploy migriert wurde.
            if ! assert_rollback_safe "int"; then
                echo -e "${RED}=== ⚠ ROLLBACK BLOCKIERT (INT): seit dem letzten Deploy sind DB-Migrationen gelaufen ===${NC}"
                echo -e "${YELLOW}Der neue (migrierte) Slot bleibt aktiv. Forward-Fix deployen oder INT-DB manuell richten,${NC}"
                echo -e "${YELLOW}danach ggf. 'switch_active int ${OLD_SLOT}'.${NC}"
                return 1
            fi
            echo -e "${YELLOW}Rolling back: nginx zurück auf ${OLD_SLOT} (läuft noch)...${NC}"
            switch_active "int" "$OLD_SLOT"
            # Den fehlgeschlagenen neuen Slot stoppen (keine zwei Instanzen auf derselben DB).
            stop_slot "int" "$NEW_SLOT"
            echo -e "${YELLOW}Rolled back INT to ${OLD_SLOT}${NC}"
            return 1
        fi
    fi

    # Externer Check ok (oder nicht gefordert): JETZT erst den alten Slot stoppen (mit Versions-Schutz).
    stop_slot "int" "$OLD_SLOT" "$IMAGE_TAG"

    # Erfolgreicher, extern bestätigter INT-Deploy: Migrationsstand-Marker aktualisieren (best effort).
    write_migration_marker "int"

    echo -e "${GREEN}=== DEV Deployment completed! ===${NC}"
    return 0
}

# Function to deploy to prod server (blue-green)
deploy_to_prod() {
    local WITH_HEALTH_CHECK=${1:-false}

    echo -e "${BLUE}=== Deploying to PROD Server (Blue-Green) ===${NC}"

    # Lokaler Lauf (nicht CI): ein gerade laufender CI-Rollout benutzt dieselben Slots und
    # dasselbe Staging-Jar — erst pruefen, dann anfassen. In der CI ist das die Concurrency-Gruppe.
    if [ "${CI:-}" != "true" ] && ! lokal_release_ci_frei "${RELEASE_BRANCH:-master}"; then
        return 1
    fi

    # Ensure NAS is reachable
    if ! ensure_nas_reachable; then
        echo -e "${RED}✗ Cannot deploy - NAS not reachable${NC}"
        return 1
    fi

    # Massnahme 2: Backup -> Slot -> Switch -> Stop laufen unter dem NAS-Deploy-Lock; der Lock
    # wird auf JEDEM Pfad (Erfolg, Rollback, Abbruch) wieder freigegeben.
    deploy_lock_acquire "prod" || return 1
    deploy_to_prod_gesperrt "$WITH_HEALTH_CHECK"
    local RC=$?
    deploy_lock_release "prod"
    return $RC
}

deploy_to_prod_gesperrt() {
    local WITH_HEALTH_CHECK=${1:-false}

    local RELEASE_VERSION
    RELEASE_VERSION=$(get_release_version)
    if [[ -z "$RELEASE_VERSION" || "$RELEASE_VERSION" == "0.0.0" ]]; then
        echo -e "${RED}Error: No release tag found in git!${NC}"
        echo -e "${RED}No release version available for production deployment.${NC}"
        return 1
    fi
    echo -e "${BLUE}Deploying release version: ${GREEN}${RELEASE_VERSION}${NC}"

    local ACTIVE_SLOT
    ACTIVE_SLOT=$(get_active_slot "prod")
    echo -e "${BLUE}Current active slot: ${GREEN}${ACTIVE_SLOT}${NC}"

    # Database backup — Massnahme 3: nur, wenn das Release eine neue Migration mitbringt.
    echo ""
    BACKUP_PATH=""
    if backup_noetig; then
        BACKUP_PATH=$(backup_prod_db)
        BACKUP_RESULT=$?
        if [ $BACKUP_RESULT -ne 0 ]; then
            echo -e "${RED}=== Database backup failed! Aborting deployment. ===${NC}"
            return 1
        fi
        echo -e "${GREEN}✓ Backup created: $(basename $BACKUP_PATH)${NC}"
    fi
    echo ""

    # Deploy to inactive PROD slot
    if ! deploy_blue_green "prod" "$RELEASE_VERSION"; then
        echo -e "${RED}=== PROD Blue-Green Deployment FAILED ===${NC}"
        echo -e "${YELLOW}Active slot (${BG_ALT_SLOT:-$ACTIVE_SLOT}) unchanged (Traffic).${NC}"
        # Der neue Slot bootete VOR seinem internen Healthcheck und kann dabei bereits Migrationen gegen
        # die geteilte DB gefahren haben, obwohl kein Traffic umgeschaltet wurde -> nicht falsch entwarnen.
        local _MARKER _CUR
        _MARKER=$(get_migration_marker "prod")
        _CUR=$(get_db_migration_rank "prod")
        if [ -n "$_MARKER" ] && [ -n "$_CUR" ] && [ "$_CUR" -gt "$_MARKER" ]; then
            echo -e "${RED}⚠ ACHTUNG: Traffic blieb auf ${ACTIVE_SLOT}, ABER die DB wurde bereits migriert (rank ${_MARKER} -> ${_CUR}).${NC}"
            echo -e "${YELLOW}   Der alte Code läuft nun gegen ein neueres Schema. Forward-Fix deployen oder DB restoren:${NC}"
            echo -e "${YELLOW}   restore_prod_db '${BACKUP_PATH}'${NC}"
        else
            echo -e "${YELLOW}Keine neue Migration erkannt. No rollback needed.${NC}"
        fi
        echo -e "${GREEN}Backup available at: $(backup_bezeichnung)${NC}"
        return 1
    fi
    # Massnahme 1: ab hier gelten die Slots, die deploy_blue_green tatsaechlich benutzt hat.
    ACTIVE_SLOT="${BG_ALT_SLOT:-$ACTIVE_SLOT}"
    local NEW_SLOT="${BG_NEU_SLOT:-}"
    if [ -z "$NEW_SLOT" ]; then
        if [ "$ACTIVE_SLOT" == "blue" ]; then NEW_SLOT="green"; else NEW_SLOT="blue"; fi
    fi

    # External health check via nginx port
    if [ "$WITH_HEALTH_CHECK" == "true" ]; then
        echo ""
        if ! check_version "$RELEASE_VERSION" "http://${NAS_HOST}:${PROD_PORT:-1122}/nosec/version"; then
            echo -e "${RED}=== PROD external health check FAILED ===${NC}"

            # Migrations-Guard: liefen seit dem letzten Deploy Migrationen gegen die geteilte DB, würde
            # ein blindes Zurückschalten den ALTEN Code gegen das NEUE Schema laufen lassen.
            if ! assert_rollback_safe "prod"; then
                echo -e "${RED}=== ⚠ ROLLBACK BLOCKIERT: seit dem letzten Deploy sind DB-Migrationen gelaufen ===${NC}"
                echo -e "${RED}Ein blindes Zurückschalten auf ${ACTIVE_SLOT} würde ALTEN Code gegen das NEUE DB-Schema laufen lassen.${NC}"
                echo -e "${YELLOW}Der neue (migrierte) Slot bleibt bewusst AKTIV (Code passt zum Schema). Optionen:${NC}"
                echo -e "${YELLOW}  1) Forward-Fix als neuen Release deployen (empfohlen), ODER${NC}"
                echo -e "${YELLOW}  2) DB restore + manueller Rollback:${NC}"
                echo -e "${YELLOW}       restore_prod_db '${BACKUP_PATH}'  &&  switch_active prod ${ACTIVE_SLOT}${NC}"
                echo -e "${YELLOW}DB backup available at: $(backup_bezeichnung)${NC}"
                echo -e "${YELLOW}(Guard umgehen: MIGRATION_GUARD_STRICT=false ändert nichts hier; für erzwungenen Blind-Rollback manuell switch_active nutzen.)${NC}"
                return 1
            fi

            echo -e "${YELLOW}=== Instant rollback: nginx zurück auf ${ACTIVE_SLOT} (läuft noch) ===${NC}"

            switch_active "prod" "$ACTIVE_SLOT"

            # Fehlgeschlagenen neuen Slot stoppen (keine zwei Instanzen auf derselben DB).
            stop_slot "prod" "$NEW_SLOT"

            echo -e "${YELLOW}=== ROLLBACK COMPLETED ===${NC}"
            echo -e "${YELLOW}PROD back on ${ACTIVE_SLOT}${NC}"
            echo -e "${YELLOW}DB backup available at: $(backup_bezeichnung)${NC}"
            echo -e "${YELLOW}For DB restore: restore_prod_db '${BACKUP_PATH}'${NC}"
            return 1
        fi
    fi

    # Externer Check ok (oder nicht gefordert): JETZT erst den alten Slot stoppen — mit
    # Versions-Schutz: ein Container, der schon die neue Version meldet, wird nie gestoppt.
    stop_slot "prod" "$ACTIVE_SLOT" "$RELEASE_VERSION"

    # Erfolgreicher, extern bestätigter Deploy: aktuellen DB-Migrationsstand als "letzter guter" Marker
    # festhalten (dient dem Rollback-Guard des NÄCHSTEN Deploys). Best effort.
    write_migration_marker "prod"

    echo -e "${GREEN}=== PROD Deployment completed! ===${NC}"
    echo -e "${GREEN}Deployed version: ${RELEASE_VERSION}${NC}"
    echo -e "${GREEN}Backup available at: $(backup_bezeichnung)${NC}"
    return 0
}

# Function to compare versions and auto-increment if needed
# ── Version Initialization (reads from pom.xml + git tags) ────

init_versions() {
    CURRENT_VERSION=$(get_pom_version)
    RELEASE_VERSION=$(get_release_version)

    if [[ -z "$CURRENT_VERSION" || "$CURRENT_VERSION" == "null" ]]; then
        CURRENT_VERSION="1.0.0-SNAPSHOT"
        echo -e "${YELLOW}Could not read version from pom.xml, using ${CURRENT_VERSION}${NC}"
    fi

    echo -e "${BLUE}Current version: ${GREEN}${CURRENT_VERSION}${NC}"
    if [[ -n "$RELEASE_VERSION" && "$RELEASE_VERSION" != "0.0.0" ]]; then
        echo -e "${BLUE}Last release:    ${GREEN}${RELEASE_VERSION}${NC}"
    fi
}

# ── Workflow Functions ────────────────────────────────────────

# Build + Run locally (no Docker)
do_run() {
    echo -e "${YELLOW}=== Build + Run (local) ===${NC}"

    echo -e "${BLUE}Building with Maven...${NC}"
    mvn clean package -DskipTests

    echo -e "${GREEN}=== Build OK - Starting application ===${NC}"
    JAR_FILE=$(ls -1 ${WEBAPP_MODULE}/target/${WEBAPP_MODULE}-*.jar 2>/dev/null | grep -v original | head -1)
    if [[ -z "$JAR_FILE" ]]; then
        echo -e "${RED}Error: JAR file not found${NC}"
        exit 1
    fi

    # Start PostgreSQL container if not running
    if command -v podman &>/dev/null; then
        echo -e "${BLUE}Starting PostgreSQL container...${NC}"
        podman compose -f "$SCRIPT_DIR/compose.yaml" up -d 2>/dev/null || true
    elif command -v docker &>/dev/null; then
        echo -e "${BLUE}Starting PostgreSQL container...${NC}"
        docker compose -f "$SCRIPT_DIR/compose.yaml" up -d 2>/dev/null || true
    fi

    echo -e "${BLUE}Running: ${GREEN}${JAR_FILE}${NC}"
    (sleep 2; while ! curl -s -o /dev/null http://localhost:8080 2>/dev/null; do sleep 1; done; open http://localhost:8080) &
    exec java -jar "$JAR_FILE"
}

# Build with Maven (SNAPSHOT), $1=optional "deploy" arg
do_build_snapshot() {
    echo -e "${YELLOW}=== Maven Build (SNAPSHOT) ===${NC}"

    echo -e "${BLUE}Building with Maven...${NC}"
    # M1 (build once): die CI gibt MVN_TEST_FLAG (-DskipITs) explizit per Env vor → Unit-Tests im
    # EINZIGEN Build; lokal (ohne diese Vorgabe) ohne Tests (Dev-Rechner/Nacht-Runner ohne Test-DB).
    local TEST_FLAG="${MVN_TEST_FLAG:--DskipTests}"
    echo -e "${BLUE}Maven-Test-Flag: ${TEST_FLAG} (CI=${CI:-unset})${NC}"
    if ! mvn clean package ${TEST_FLAG} -B; then
        echo -e "${RED}✗ Maven build failed!${NC}"
        return 1
    fi

    if [ "${JAR_VOLUME_DEPLOY}" == "true" ]; then
        # M3: kein Image-Bau/Transfer — nur das Jar ins NAS-Staging (deploy_blue_green verteilt es)
        echo -e "${BLUE}M3 (Jar im Volume): überspringe docker build/push, stage Jar...${NC}"
        stage_jar_to_nas || return 1
    else
        ensure_podman_running || return 1

        echo -e "${BLUE}Building Docker image with tag: ${GREEN}latest${NC}"
        if [[ "$CONTAINER_CLI" == *"podman"* ]]; then
            $CONTAINER_CLI build --platform linux/amd64 --format docker -t "${IMAGE_NAME}:latest" .
        else
            $CONTAINER_CLI build --platform linux/amd64 -t "${IMAGE_NAME}:latest" .
        fi

        push_to_registry "latest"
    fi

    echo -e "${GREEN}=== Build completed successfully! ===${NC}"

    if [ "$1" == "deploy" ]; then
        deploy_to_dev "latest"
    elif [ "$1" == "prod-single" ]; then
        if ! deploy_prod_single; then
            echo -e "${RED}=== Single-PROD-Deployment FEHLGESCHLAGEN ===${NC}"
            return 1
        fi
    fi
}

# Single-PROD-Deploy (kein blue-green, kein DEV): recreate den EINEN PROD-Container mit dem frisch
# geladenen :latest-Image. Der Stack (Container + DB) wird einmalig per gitops angelegt
# (./build deploy tri/${IMAGE_NAME} im plaintext-dockercompose-Repo); danach aktualisiert dies nur
# den App-Container. ${DEPLOY_PATH}=NAS-Compose-Verzeichnis, ${IMAGE_NAME}-prod=Container, ${PROD_PORT}.
deploy_prod_single() {
    echo -e "${BLUE}=== Single-PROD-Deploy (kein blue-green) ===${NC}"
    if ! ensure_nas_reachable; then
        echo -e "${RED}✗ NAS nicht erreichbar${NC}"
        return 1
    fi
    local CONTAINER="${IMAGE_NAME}-prod"
    if ! ssh "${DEPLOY_SERVER}" "test -f ${DEPLOY_PATH}/docker-compose.yaml"; then
        echo -e "${YELLOW}Compose ${DEPLOY_PATH}/docker-compose.yaml fehlt — Image geladen, aber Stack noch nicht via gitops angelegt (./build deploy tri/${IMAGE_NAME}). Container-Recreate übersprungen.${NC}"
        return 0
    fi
    if [ "${JAR_VOLUME_DEPLOY}" == "true" ]; then
        # M3: Staging-Jar in den prod-Slot kopieren (Compose mountet jars/prod/app.jar als Volume).
        if ! ssh "${DEPLOY_SERVER}" "test -f ${DEPLOY_PATH}/jars/staging/app.jar"; then
            echo -e "${RED}✗ M3: Kein Staging-Jar gefunden (stage_jar_to_nas gelaufen?)${NC}"
            return 1
        fi
        # Kein IMAGE_TAG-Parameter hier (dieser Pfad prueft sonst nur "latest"/SKIP_VERSION_MATCH,
        # s. check_version-Aufruf unten) -- frisch aus dem lokalen pom.xml gelesene Version nutzen,
        # da cwd hier das gerade gebaute App-Repo-Root ist.
        if ! verify_staging_jar_version "$(get_pom_version)"; then
            return 1
        fi
        ssh "${DEPLOY_SERVER}" "mkdir -p ${DEPLOY_PATH}/jars/prod && \
            cp -f ${DEPLOY_PATH}/jars/staging/app.jar ${DEPLOY_PATH}/jars/prod/app.jar && \
            chmod 644 ${DEPLOY_PATH}/jars/prod/app.jar"
        echo -e "${BLUE}M3: Jar im prod-Slot — recreate ${CONTAINER} (stabiles runtime-Image)...${NC}"
    else
        echo -e "${BLUE}Recreate ${CONTAINER} mit frischem ${IMAGE_NAME}:latest...${NC}"
    fi
    # KEIN --no-deps: stellt sicher, dass die DB-Dependency läuft (depends_on), bevor die App startet.
    if ! ssh "${DEPLOY_SERVER}" "cd ${DEPLOY_PATH} && sudo docker compose up -d --force-recreate ${CONTAINER}"; then
        echo -e "${RED}✗ docker compose up fehlgeschlagen${NC}"
        return 1
    fi
    # Karte 379: neuer Container == potenziell neue IP -> nginx muss neu aufloesen.
    nginx_reload_after_recreate "Single-PROD-Recreate ${CONTAINER}"
    # 300s statt der 120s-Vorgabe (Karte 555): dieser Pfad startet die JVM gedrosselt
    # (-XX:ActiveProcessorCount=2, Karte 351) und lief unter Runner-Last zweimal ins Timeout,
    # obwohl der Deploy in Ordnung war. Container-Name mitgeben, damit ein echter Fehlschlag
    # seine Logs zeigt statt nur "HTTP status: 000".
    if ! check_version "latest" "http://${NAS_HOST}:${PROD_PORT:-1142}/nosec/version" 300 "${CONTAINER}"; then
        echo -e "${RED}=== Single-PROD-Healthcheck FEHLGESCHLAGEN ===${NC}"
        return 1
    fi
    echo -e "${GREEN}=== Single-PROD-Deploy abgeschlossen ===${NC}"
    return 0
}

# ── Versionsschritt (rein rechnend, ohne Seiteneffekte -> testbar) ──────────
# $1 = aktuelle POM-Version (z.B. "1.616.0-SNAPSHOT"), $2 = Increment-Typ (1=MAJOR, 2=MINOR, 3=PATCH)
# Ausgabe auf stdout: "<Release-Version> <naechste-SNAPSHOT-Version>"
#
# WARUM DIE NAECHSTE SNAPSHOT-VERSION DIE RELEASE-NUMMER TRAEGT (und nicht die darauf folgende):
# Die Release-Nummer wird aus der POM-Version GERECHNET (POM-Version + ein Schritt). Traegt die
# POM nach dem Release bereits die naechste Nummer, rechnet der folgende Lauf ein zweites Mal
# hoch — und jede zweite Nummer bleibt unbenutzt. Genau so lief es bis zum 28.08.2026:
# plaintext-root ging 1.605 -> 1.607 -> 1.609 -> 1.611, plaintext-app 2.376 -> 2.378 -> 2.380,
# plaintext-iot 1.330 -> 1.332 -> 1.334. Der SNAPSHOT gehoert deshalb auf die GERADE
# veroeffentlichte Nummer; hochgezaehlt wird erst wieder beim naechsten Release.
# Wer hier umbaut, laesst test-versionsschritt.sh laufen.
compute_release_versions() {
    local CURRENT="${1%-SNAPSHOT}"
    local TYPE="${2:-2}"
    local MAJOR MINOR PATCH

    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
    MAJOR="${MAJOR:-0}"
    MINOR="${MINOR:-0}"
    PATCH="${PATCH:-0}"

    case "$TYPE" in
        1) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        3) PATCH=$((PATCH + 1)) ;;
        *) MINOR=$((MINOR + 1)); PATCH=0 ;;
    esac

    local NEU="${MAJOR}.${MINOR}.${PATCH}"
    echo "${NEU} ${NEU}-SNAPSHOT"
}

# Release build, $1=increment type or deploy flag, $2=optional deploy flag
do_release() {
    echo -e "${YELLOW}=== Release Build ===${NC}"

    INCREMENT_TYPE="2"
    DEPLOY_REQUESTED=false
    DEPLOY_TO_PROD=false
    DEPLOY_TO_BOTH=false
    DEPLOY_WITH_HEALTHCHECK=false

    if [ "$1" == "deploy" ]; then
        DEPLOY_REQUESTED=true
    elif [ "$1" == "deploy-prod" ]; then
        DEPLOY_TO_PROD=true
    elif [ "$1" == "deploy-both" ]; then
        DEPLOY_TO_BOTH=true
    elif [ "$1" == "deploy-healthcheck" ]; then
        DEPLOY_WITH_HEALTHCHECK=true
    elif [ "$1" == "1" ] || [ "$1" == "2" ] || [ "$1" == "3" ]; then
        INCREMENT_TYPE="$1"
        if [ "$2" == "deploy" ]; then
            DEPLOY_REQUESTED=true
        elif [ "$2" == "deploy-prod" ]; then
            DEPLOY_TO_PROD=true
        elif [ "$2" == "deploy-both" ]; then
            DEPLOY_TO_BOTH=true
        elif [ "$2" == "deploy-healthcheck" ]; then
            DEPLOY_WITH_HEALTHCHECK=true
        fi
    fi

    case "$INCREMENT_TYPE" in
        1) echo -e "${YELLOW}Incrementing MAJOR version${NC}" ;;
        3) echo -e "${YELLOW}Incrementing PATCH version${NC}" ;;
        *) echo -e "${YELLOW}Incrementing MINOR version (default)${NC}" ;;
    esac

    # Lokaler Lauf (nicht CI): derselbe Vorflug wie beim Lokal-Release (./build 8) — master,
    # Arbeitsbaum, origin nachgezogen, kein CI-Rollout aktiv, Maven-Zugangsdaten — und der
    # Release-Commit bekommt [skip-ci]. Sonst wuerde der Push dieses Commits die CI-Pipeline
    # starten, die parallel zu ./build 5/56/7 einen ZWEITEN Release deployt (Karte: Lokal-Release,
    # 29.08.2026). In der CI (CI=true) aendert sich hier nichts.
    if [ "${CI:-}" != "true" ]; then
        if ! lokal_vorflug; then
            return 1
        fi
        : "${RELEASE_COMMIT_SUFFIX= [skip-ci]}"
    fi

    read -r NEW_VERSION NEXT_SNAPSHOT_VERSION <<< "$(compute_release_versions "$CURRENT_VERSION" "$INCREMENT_TYPE")"
    echo -e "${BLUE}New release version: ${GREEN}${NEW_VERSION}${NC}"
    echo -e "${BLUE}Next SNAPSHOT version: ${GREEN}${NEXT_SNAPSHOT_VERSION}${NC}"

    # Karte 410 (M3): Kollisionspruefung VOR dem Build. Ist ${NEW_VERSION} im Release-Repo
    # bereits veroeffentlicht, ist master nicht auf dem Stand des letzten Release — typischerweise
    # weil ein Release-Commit verlorenging (siehe M1). Ohne diese Pruefung laeuft der Build sechs
    # Minuten und stirbt dann am 409 des maven-deploy-plugin, mit einer Meldung, die die Ursache
    # nicht nennt. Ein HTTP-HEAD kostet Millisekunden.
    RELEASE_REPO_URL="${RELEASE_REPO_URL:-https://maven.plaintext.ch/releases}"
    REL_GROUP="$(mvn -q -N help:evaluate -Dexpression=project.groupId -DforceStdout 2>/dev/null | tr . /)"
    REL_ARTIFACT="$(mvn -q -N help:evaluate -Dexpression=project.artifactId -DforceStdout 2>/dev/null)"
    if [ -n "$REL_GROUP" ] && [ -n "$REL_ARTIFACT" ]; then
        REL_URL="${RELEASE_REPO_URL}/${REL_GROUP}/${REL_ARTIFACT}/${NEW_VERSION}/${REL_ARTIFACT}-${NEW_VERSION}.pom"
        if [ "$(curl -s -o /dev/null -w '%{http_code}' "$REL_URL")" = "200" ]; then
            echo -e "${RED}✗ Version ${NEW_VERSION} ist im Release-Repo bereits veroeffentlicht.${NC}"
            echo -e "${RED}  master ist nicht auf dem Stand des letzten Release — vermutlich ging ein"
            echo -e "  Release-Commit verloren (Karte 410). Erst master nachziehen, dann erneut.${NC}"
            return 1
        fi
    else
        # Eine nicht durchfuehrbare Vorpruefung darf keinen Release blockieren.
        echo -e "${YELLOW}⚠ Maven-Koordinaten nicht ermittelbar — Kollisionspruefung uebersprungen.${NC}"
    fi

    echo -e "${BLUE}Maven: Setting version to ${GREEN}${NEW_VERSION}${NC}"
    mvn versions:set -DnewVersion="${NEW_VERSION}" -DgenerateBackupPoms=false

    echo -e "${BLUE}Git: Checking for changes to include in release ${NEW_VERSION}...${NC}"

    echo -e "${YELLOW}Current git status:${NC}"
    git --no-pager status --short

    echo -e "${BLUE}Git: Adding all changes for release commit...${NC}"
    git add -A || true

    echo -e "${YELLOW}Changes to be committed:${NC}"
    git --no-pager diff --cached --name-status || echo "No changes"

    # RELEASE_COMMIT_SUFFIX: leer im CI-Lauf. Der Lokal-Release (do_local_release) setzt
    # " [skip-ci]" — der Push dieses Commits auf master wuerde sonst die CI-Pipeline
    # (release-all) starten, die parallel zum lokalen Deploy einen ZWEITEN Release rechnet.
    # Die skip-pruefung der App-Pipeline fuehrt "Release version" als Automatik-Commit.
    COMMIT_MSG="Release version ${NEW_VERSION}${RELEASE_COMMIT_SUFFIX:-}

Includes:
- Version update to ${NEW_VERSION}
- Maven POMs updated
- All pending changes from development
"

    echo -e "${BLUE}Git: Committing version ${NEW_VERSION}...${NC}"
    git commit -m "$COMMIT_MSG" || {
        echo -e "${YELLOW}No changes to commit (maybe already committed?)${NC}"
    }

    echo -e "${BLUE}Git: Creating tag ${NEW_VERSION}...${NC}"
    git tag -a "${NEW_VERSION}" -m "Release version ${NEW_VERSION}"

    # Karte 518: DER RELEASE-COMMIT GEHT RAUS, BEVOR IRGENDETWAS VEROEFFENTLICHT WIRD.
    #
    # Vorher lag der einzige `git push` ganz am Ende — nach `mvn deploy`, nach dem Jar aufs NAS,
    # nach dem SNAPSHOT-Commit. Brach eine dieser Stufen ab, war die Version im Release-Repo
    # (unumkehrbar), master kannte sie aber nicht. Da die naechste Versionsnummer aus der
    # POM-Version von master abgeleitet wird, berechnete der naechste Lauf DIESELBE Version und
    # starb an der Kollisionspruefung. Am 03.08.2026 sind daran sieben master-Laeufe gescheitert;
    # vier gemergte Karten lagen dadurch ungenutzt auf master.
    #
    # Jetzt ist der Push der frueheste Punkt, an dem etwas schiefgehen darf: Schlaegt er fehl, ist
    # NICHTS veroeffentlicht und der Zustand bleibt konsistent — der Lauf laesst sich einfach
    # wiederholen. Gelingt er, ist master mindestens so weit wie das Release-Repo, und ein
    # spaeterer Abbruch kostet hoechstens den SNAPSHOT-Commit (Kosmetik, keine Blockade).
    echo -e "${BLUE}Git: Pushing release commit + tag BEFORE publishing...${NC}"
    if ! git push; then
        echo -e "${RED}✗ Push des Release-Commits abgelehnt — master hat sich inzwischen bewegt.${NC}"
        echo -e "${RED}  Es wurde NICHTS veroeffentlicht; der Zustand ist konsistent.${NC}"
        echo -e "${YELLOW}  Naechster Schritt: git pull --rebase, dann den Release erneut starten.${NC}"
        return 1
    fi
    # NUR den neuen Tag pushen — `git push --tags` schiebt ALLE lokalen Tags und scheitert an
    # alten, vom Remote abweichenden Tags (plaintext-app: v56.x, dieselbe Falle wie beim
    # `fetch --tags` im Vorflug). Am 29.08.2026 brach so ein Lokal-Release nach Commit+Tag ab,
    # obwohl der Tag laengst draussen war (2.1708.0: Tag ohne Artefakt).
    if ! git push origin "refs/tags/${NEW_VERSION}"; then
        echo -e "${RED}✗ Tag-Push fehlgeschlagen — Tag ${NEW_VERSION} fehlt auf dem Remote.${NC}"
        echo -e "${RED}  Es wurde NICHTS veroeffentlicht; erst den Tag klaeren, dann erneut.${NC}"
        return 1
    fi

    # M1 (build once): die CI gibt MVN_TEST_FLAG (-DskipITs) explizit per Env vor → Unit-Tests im
    # EINZIGEN Build; lokal (ohne diese Vorgabe) ohne Tests (Dev-Rechner/Nacht-Runner ohne Test-DB).
    local TEST_FLAG="${MVN_TEST_FLAG:--DskipTests}"
    echo -e "${BLUE}Maven-Test-Flag: ${TEST_FLAG} (CI=${CI:-unset})${NC}"
    # Release-Builds IMMER cache-frei: Der Build-Cache restauriert die Webapp sonst mit dem
    # Inhalt des PR-/Branch-Builds — das Jar wird zwar auf die Release-Version umbenannt
    # (projectVersioning), traegt im Inhalt aber die SNAPSHOT-Version. Der /nosec/version-Gate
    # des Blue-Green-Deploys lehnt das (korrekterweise) ab (schuetu 1.371.0, 17.07.2026).
    # Der Cache-Gewinn bleibt fuer ci/PR/snapshot-Builds erhalten.
    local RELEASE_MVN_FLAGS="-Dmaven.build.cache.enabled=false"
    if [ "${MVN_RELEASE_DEPLOY}" == "true" ]; then
        echo -e "${BLUE}Maven: Building + deploying version ${GREEN}${NEW_VERSION}${NC} (${TEST_FLAG}, cache-frei)"
        if ! mvn clean deploy ${TEST_FLAG} ${RELEASE_MVN_FLAGS} -B; then
            echo -e "${RED}✗ Maven build failed!${NC}"
            return 1
        fi
    else
        echo -e "${BLUE}Maven: Building version ${GREEN}${NEW_VERSION}${NC} (${TEST_FLAG}, cache-frei)"
        if ! mvn clean package ${TEST_FLAG} ${RELEASE_MVN_FLAGS} -B; then
            echo -e "${RED}✗ Maven build failed!${NC}"
            return 1
        fi
    fi

    if [ "${JAR_VOLUME_DEPLOY}" == "true" ]; then
        # M3: kein per-Version-Image — nur das Jar ins NAS-Staging (deploy_blue_green verteilt es)
        echo -e "${BLUE}M3 (Jar im Volume): überspringe docker build/push, stage Jar ${NEW_VERSION}...${NC}"
        if ! stage_jar_to_nas; then
            echo -e "${RED}✗ M3: Jar-Staging fehlgeschlagen!${NC}"
            return 1
        fi
    else
        ensure_podman_running || return 1

        echo -e "${BLUE}Building Docker image with tags: ${GREEN}${NEW_VERSION}${BLUE} and ${GREEN}latest${NC}"
        if [[ "$CONTAINER_CLI" == *"podman"* ]]; then
            if ! $CONTAINER_CLI build --platform linux/amd64 --format docker -t "${IMAGE_NAME}:${NEW_VERSION}" -t "${IMAGE_NAME}:latest" .; then
                echo -e "${RED}✗ Docker image build failed!${NC}"
                return 1
            fi
        else
            if ! $CONTAINER_CLI build --platform linux/amd64 -t "${IMAGE_NAME}:${NEW_VERSION}" -t "${IMAGE_NAME}:latest" .; then
                echo -e "${RED}✗ Docker image build failed!${NC}"
                return 1
            fi
        fi

        if ! push_to_registry "${NEW_VERSION}"; then
            echo -e "${RED}✗ Image push to NAS failed!${NC}"
            return 1
        fi
    fi

    echo -e "${BLUE}Maven: Preparing next SNAPSHOT version ${GREEN}${NEXT_SNAPSHOT_VERSION}${NC}"
    mvn versions:set -DnewVersion="${NEXT_SNAPSHOT_VERSION}" -DgenerateBackupPoms=false

    echo -e "${BLUE}Git: Committing next SNAPSHOT version...${NC}"
    git add pom.xml "*/pom.xml" || true
    git commit -m "Prepare next development iteration ${NEXT_SNAPSHOT_VERSION} [skip-ci]"

    # Karte 410 (M1): Der Rueckgabewert BEIDER Pushes muss geprueft werden.
    # Am 01.08.2026 wurde `git push` abgelehnt ("! [rejected] master -> master (fetch first)"),
    # das Skript lief weiter und meldete "Release 2.1400.0 completed successfully!" — der Job
    # wurde gruen. Folge: 2.1400.0 war veroeffentlicht, master kannte den Release-Commit nicht,
    # und jeder weitere Lauf rechnete dieselbe Version und starb nach ~6 Minuten Build am
    # 409 Conflict des maven-deploy-plugin. `set -e` greift an dieser Stelle nachweislich nicht,
    # deshalb wird explizit geprueft.
    #
    # REIHENFOLGE IST TEIL DES FIX: Der Tag geht erst raus, wenn der Branch-Push gelungen ist.
    # Andersherum entsteht genau der verwaiste Zustand vom 01.08. (Tag 2.1400.0 veroeffentlicht,
    # Commit 971e5190 nie auf master). Beim naechsten Umbau nicht wieder tauschen.
    # Karte 518: Release-Commit UND Tag sind oben schon draussen (vor dem Veroeffentlichen).
    # Hier geht nur noch der SNAPSHOT-Commit raus. Scheitert das, ist der Release trotzdem
    # vollstaendig und konsistent — master traegt die Release-Version, das Repo kennt den Tag,
    # und der naechste Lauf rechnet korrekt weiter. Deshalb ist das ab jetzt eine WARNUNG und
    # kein Abbruch: Ein kosmetischer Rueckstand darf keinen gelungenen Release rot faerben.
    echo -e "${BLUE}Git: Pushing next SNAPSHOT commit...${NC}"
    if ! git push; then
        echo -e "${YELLOW}⚠ Push des SNAPSHOT-Commits abgelehnt — master hat sich waehrend des"
        echo -e "  Releases bewegt. Der Release ${NEW_VERSION} ist vollstaendig (Commit und Tag"
        echo -e "  sind draussen); es fehlt nur die Vorbereitung auf ${NEXT_SNAPSHOT_VERSION}.${NC}"
        echo -e "${YELLOW}  Nachziehen: git pull --rebase && git push${NC}"
    fi

    echo -e "${GREEN}=== Release ${NEW_VERSION} completed successfully! ===${NC}"
    echo -e "${GREEN}=== Next development version: ${NEXT_SNAPSHOT_VERSION} ===${NC}"

    if [ "$DEPLOY_REQUESTED" == "true" ]; then
        deploy_to_dev "${NEW_VERSION}"
    elif [ "$DEPLOY_TO_PROD" == "true" ]; then
        deploy_to_prod
    elif [ "$DEPLOY_TO_BOTH" == "true" ]; then
        deploy_to_dev "${NEW_VERSION}"
        deploy_to_prod
    elif [ "$DEPLOY_WITH_HEALTHCHECK" == "true" ]; then
        if ! deploy_to_dev "${NEW_VERSION}" "true"; then
            echo -e "${RED}=== Deployment with health check FAILED ===${NC}"
            exit 1
        fi
    fi
}

# ── Lokal-Release: zweiter Weg neben CI/CD ─────────────────────────────────────
# Release (Version, Commit, Tag, Push) + Build + Blue-Green-Deploy — komplett von dieser
# Maschine aus, ohne GitHub Actions. Aufruf ueber den Wrapper:
#   plaintext-app: ./build 8   bzw.   ./build local-release [1|2|3] [prod|dev-prod]
#   $1 = Increment-Typ (1=MAJOR, 2=MINOR (Default), 3=PATCH)
#   $2 = Ziel: "prod" (Default: direkt PROD) | "dev-prod" (erst DEV, dann PROD — wie CI release-all)
#
# WARUM NICHT EINFACH ./build 56?
#   1. Der Push des Release-Commits loest die CI aus (push auf master -> release-all). Die
#      wuerde parallel zum lokalen Deploy einen ZWEITEN Release rechnen und gegen dieselben
#      Slots und dasselbe Staging-Jar deployen. Deshalb traegt der lokale Release-Commit
#      "[skip-ci]" (RELEASE_COMMIT_SUFFIX); die skip-pruefung der App-Pipeline fuehrt
#      "Release version" als Automatik-Commit, damit kein Pushover-Alarm ausgeloest wird.
#   2. do_release macht `git add -A`: alles Ungespeicherte wanderte in den Release. Hier ist
#      ein sauberer, auf origin nachgezogener master Pflicht — sonst Abbruch VOR dem Tag.
#   3. Lokal fehlen typischerweise die Reposilite-Zugangsdaten (server-id aus
#      distributionManagement). `mvn deploy` scheiterte dann NACH Tag+Push -> Tag ohne
#      Artefakt. Deshalb Vorpruefung: ohne Zugangsdaten wird nur gebaut (mvn package).
#   4. Der Tag darf erst entstehen, wenn das NAS erreichbar ist — sonst Tag ohne Deploy.
#   5. Scheitert der Push des Release-Commits, werden lokaler Commit und Tag zurueckgenommen
#      (auf origin ist dann nichts angekommen, der Lauf laesst sich einfach wiederholen).
#
# Tests: standardmaessig wie bei jedem lokalen Build ohne (MVN_TEST_FLAG=-DskipTests) — die
# DB-gestuetzten Tests brauchen die CI-Datenbank. Wer lokal eine Test-DB hat:
#   MVN_TEST_FLAG="-DskipITs -DexcludedGroups=quality-gate" ./build 8
#
# Nur Vorflug, ohne Seiteneffekte:   LOKAL_RELEASE_NUR_VORFLUG=true ./build 8
# CI-Sperre uebergehen (mit Grund):  LOKAL_RELEASE_IGNORIERE_CI=true ./build 8
do_local_release() {
    local INCREMENT_TYPE="${1:-2}"
    local ZIEL="${2:-prod}"
    local BRANCH="${RELEASE_BRANCH:-master}"

    echo -e "${YELLOW}=== Lokal-Release: Release + Tag + Blue-Green ${ZIEL} (ohne CI) ===${NC}"

    case "$INCREMENT_TYPE" in
        1|2|3) ;;
        *) echo -e "${RED}✗ Ungueltiger Increment-Typ '${INCREMENT_TYPE}' (1=MAJOR, 2=MINOR, 3=PATCH)${NC}"; return 1 ;;
    esac
    case "$ZIEL" in
        prod|dev-prod) ;;
        *) echo -e "${RED}✗ Ungueltiges Ziel '${ZIEL}' (prod | dev-prod)${NC}"; return 1 ;;
    esac

    # ── Vorflug 1-3: Git, CI, Maven (geteilt mit do_release im lokalen Lauf) ─
    if ! lokal_vorflug "$BRANCH"; then
        return 1
    fi

    # ── Vorflug 4: NAS erreichbar — VOR dem Tag ──────────────────────────────
    if ! ensure_nas_reachable; then
        echo -e "${RED}✗ NAS nicht erreichbar — es wird KEIN Release angelegt (kein Tag ohne Deploy).${NC}"
        return 1
    fi

    # ── Vorflug 5: der geplante Tag darf auf origin noch nicht existieren (Massnahme 5) ─
    local PLAN_NEU
    read -r PLAN_NEU _ <<< "$(compute_release_versions "$CURRENT_VERSION" "$INCREMENT_TYPE")"
    if git ls-remote --tags origin "refs/tags/${PLAN_NEU}" 2>/dev/null | grep -q .; then
        echo -e "${RED}✗ Tag ${PLAN_NEU} existiert bereits auf origin — POM-Version und Tags passen nicht zusammen.${NC}"
        echo -e "${YELLOW}  git fetch --tags; git tag --sort=-v:refname | head; POM-Version pruefen — erst dann erneut.${NC}"
        return 1
    fi

    # ── Vorflug 6: Unit-Tests im Release-Build, wenn eine Test-DB da ist (Massnahme 4) ──
    lokal_release_testflag

    # ── Plan ─────────────────────────────────────────────────────────────────
    echo ""
    echo -e "${BLUE}Plan:${NC}"
    echo -e "  Version:   ${CURRENT_VERSION} -> ${GREEN}${PLAN_NEU}${NC} (Tag ${PLAN_NEU}, Commit mit [skip-ci])"
    echo -e "  Build:     mvn clean $([ "${MVN_RELEASE_DEPLOY:-false}" == "true" ] && echo deploy || echo package) ${MVN_TEST_FLAG:--DskipTests}"
    echo -e "  Transport: $([ "${JAR_VOLUME_DEPLOY}" == "true" ] && echo "Jar -> NAS-Staging (M3)" || echo "Image -> NAS-Registry")"
    echo -e "  Deploy:    Blue-Green $([ "$ZIEL" == "dev-prod" ] && echo "DEV (int) -> PROD" || echo "PROD direkt") mit Healthcheck"
    echo ""
    if [ "${LOKAL_RELEASE_NUR_VORFLUG:-false}" == "true" ]; then
        echo -e "${GREEN}=== Nur Vorflug (LOKAL_RELEASE_NUR_VORFLUG=true) — nichts veraendert. ===${NC}"
        return 0
    fi

    # ── Release: Version, Commit [skip-ci], Tag, Push, Build, Staging ─────────
    local START_SHA
    START_SHA=$(git rev-parse HEAD)
    RELEASE_COMMIT_SUFFIX=" [skip-ci]"
    if ! do_release "$INCREMENT_TYPE"; then
        RELEASE_COMMIT_SUFFIX=""
        lokal_release_rueckbau "$START_SHA" "$BRANCH"
        lokal_release_melde 1 "Release ${NEW_VERSION:-?} abgebrochen (Release-Phase). Details im Terminal."
        return 1
    fi
    RELEASE_COMMIT_SUFFIX=""

    # Der Tag ist die Quelle fuer deploy_to_prod (get_release_version). Er MUSS die eben
    # gebaute Version sein — sonst wuerde ein fremder Stand ausgerollt.
    local TAG_VERSION
    TAG_VERSION=$(get_release_version)
    if [ "$TAG_VERSION" != "$NEW_VERSION" ]; then
        echo -e "${RED}✗ Juengster Release-Tag ist '${TAG_VERSION}', gebaut wurde '${NEW_VERSION}' — kein Deploy.${NC}"
        lokal_release_melde 1 "Release ${NEW_VERSION}: Tag-Mismatch (${TAG_VERSION}), Deploy nicht gestartet."
        return 1
    fi

    # ── Deploy: Blue-Green ───────────────────────────────────────────────────
    if [ "$ZIEL" == "dev-prod" ]; then
        if ! deploy_to_dev "${NEW_VERSION}" "true"; then
            echo -e "${RED}=== Lokal-Release ${NEW_VERSION}: DEV-Deploy FEHLGESCHLAGEN — PROD nicht angefasst ===${NC}"
            lokal_release_melde 1 "Release ${NEW_VERSION}: DEV-Deploy fehlgeschlagen, PROD unveraendert."
            return 1
        fi
    fi
    if ! deploy_to_prod "true"; then
        echo -e "${RED}=== Lokal-Release ${NEW_VERSION}: PROD-Deploy FEHLGESCHLAGEN (siehe Rollback-Meldungen oben) ===${NC}"
        lokal_release_melde 1 "Release ${NEW_VERSION}: PROD-Deploy fehlgeschlagen. Rollback-Status im Terminal pruefen."
        return 1
    fi

    echo ""
    echo -e "${GREEN}=== Lokal-Release ${NEW_VERSION} ausgerollt (${ZIEL}, Blue-Green) ===${NC}"
    echo -e "${GREEN}    Tag ${NEW_VERSION} und Release-Commit sind auf origin/${BRANCH}; CI wurde bewusst uebersprungen.${NC}"
    lokal_release_melde 0 "Release ${NEW_VERSION} lokal gebaut und per Blue-Green auf ${ZIEL} ausgerollt."
    return 0
}

# Gemeinsamer Vorflug jedes LOKALEN Release-Laufs (do_release ausserhalb der CI, do_local_release):
#   1. Git: Release-Branch, sauberer Arbeitsbaum, origin per fast-forward nachgezogen.
#      do_release macht `git add -A` — alles Ungespeicherte ginge sonst in den Release. Wer das
#      bewusst will (Nacht-Runner, Hotfix aus dem Arbeitsbaum): LOKAL_RELEASE_MIT_AENDERUNGEN=true.
#   2. CI: kein Rollout auf dem Release-Branch aktiv (gleiche Slots, gleiches Staging-Jar).
#   3. Maven: Zugangsdaten fuers Release-Repo, sonst nur mvn package.
# Idempotent: ein zweiter Aufruf im selben Lauf kostet nur ein fetch.
lokal_vorflug() {
    local BRANCH="${1:-${RELEASE_BRANCH:-master}}"

    local AKTUELLER_BRANCH
    AKTUELLER_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ "$AKTUELLER_BRANCH" != "$BRANCH" ]; then
        echo -e "${RED}✗ Lokaler Release nur auf '${BRANCH}' (aktuell: '${AKTUELLER_BRANCH}').${NC}"
        echo -e "${YELLOW}  Anderer Release-Branch: RELEASE_BRANCH=<name> setzen.${NC}"
        return 1
    fi
    if [ -n "$(git status --porcelain)" ]; then
        if [ "${LOKAL_RELEASE_MIT_AENDERUNGEN:-false}" == "true" ]; then
            echo -e "${YELLOW}⚠ Arbeitsbaum nicht sauber — die Aenderungen gehen MIT in den Release-Commit (LOKAL_RELEASE_MIT_AENDERUNGEN=true):${NC}"
            git --no-pager status --short
        else
            echo -e "${RED}✗ Arbeitsbaum nicht sauber — der Release wuerde ALLES Ungespeicherte mitnehmen (git add -A).${NC}"
            git --no-pager status --short
            echo -e "${YELLOW}  Erst committen/stashen — oder bewusst: LOKAL_RELEASE_MIT_AENDERUNGEN=true${NC}"
            return 1
        fi
    fi
    echo -e "${BLUE}Git: origin nachziehen (fetch)...${NC}"
    # Bewusst OHNE --tags: lokale Tags, die vom Remote abweichen (plaintext-app: v56.x), lassen
    # `git fetch --tags` mit "would clobber existing tag" scheitern — Release-Tags (n.n.n) kommen
    # mit der Branch-Historie ohnehin mit, und do_release prueft den Tag-Push selbst.
    if ! git fetch origin -q; then
        echo -e "${RED}✗ git fetch origin fehlgeschlagen — ohne Netz kein Release.${NC}"
        return 1
    fi
    local LOKAL REMOTE BASIS
    LOKAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse "origin/${BRANCH}")
    BASIS=$(git merge-base HEAD "origin/${BRANCH}")
    if [ "$LOKAL" = "$REMOTE" ]; then
        echo -e "${GREEN}✓ ${BRANCH} ist auf dem Stand von origin${NC}"
    elif [ "$LOKAL" = "$BASIS" ]; then
        echo -e "${YELLOW}${BRANCH} liegt hinter origin — ziehe nach (fast-forward)...${NC}"
        if [ -n "$(git status --porcelain)" ]; then
            echo -e "${RED}✗ Nachziehen mit ungespeicherten Aenderungen ist nicht sicher — erst committen/stashen.${NC}"
            return 1
        fi
        if ! git pull -q --ff-only origin "$BRANCH"; then
            echo -e "${RED}✗ Fast-forward nicht moeglich.${NC}"
            return 1
        fi
        echo -e "${GREEN}✓ Nachgezogen auf $(git log --oneline -1)${NC}"
    elif [ "$REMOTE" = "$BASIS" ]; then
        local VORAUS
        VORAUS=$(git rev-list --count "origin/${BRANCH}..HEAD")
        echo -e "${YELLOW}⚠ ${VORAUS} lokale Commit(s) sind noch nicht auf origin — sie gehen mit dem Release raus:${NC}"
        git --no-pager log --oneline "origin/${BRANCH}..HEAD"
    else
        echo -e "${RED}✗ ${BRANCH} und origin/${BRANCH} sind divergiert — erst git pull --rebase, dann erneut.${NC}"
        return 1
    fi
    # Versionen NACH dem Nachziehen neu lesen: do_release rechnet aus CURRENT_VERSION.
    init_versions

    if ! lokal_release_ci_frei "$BRANCH"; then
        return 1
    fi

    lokal_release_maven_zugangsdaten
    return 0
}

# Massnahme 4 (29.08.2026): Lokal-Releases liefen grundsaetzlich mit -DskipTests — 800+ Modultests
# blind uebersprungen, weil auf dem Dev-Rechner keine Test-DB vorausgesetzt werden konnte.
# Jetzt: MVN_TEST_FLAG explizit gesetzt -> gilt. Sonst: SPRING_DATASOURCE_URL gesetzt und
# erreichbar -> Unit-Tests (wie die CI: -DskipITs -DexcludedGroups=quality-gate). Sonst wird die
# lokale Wegwerf-DB des Projekts gestartet (start-postgres.sh, podman/docker). Erst wenn auch das
# nicht geht: -DskipTests mit lauter Warnung. LOKAL_RELEASE_OHNE_TESTS=true ueberspringt bewusst.
lokal_testdb_antwortet() {
    local URL="$1" HOST PORT
    if [[ "$URL" =~ ^jdbc:postgresql://([^:/]+):?([0-9]*)/ ]]; then
        HOST="${BASH_REMATCH[1]}"; PORT="${BASH_REMATCH[2]:-5432}"
    else
        return 1
    fi
    nc -z -w 2 "$HOST" "$PORT" >/dev/null 2>&1
}
lokal_release_testflag() {
    if [ -n "${MVN_TEST_FLAG:-}" ]; then
        echo -e "${BLUE}Tests: MVN_TEST_FLAG='${MVN_TEST_FLAG}' (explizit vorgegeben)${NC}"
        return 0
    fi
    if [ "${LOKAL_RELEASE_OHNE_TESTS:-false}" == "true" ]; then
        export MVN_TEST_FLAG="-DskipTests"
        echo -e "${YELLOW}⚠ Tests bewusst uebersprungen (LOKAL_RELEASE_OHNE_TESTS=true).${NC}"
        return 0
    fi
    local URL="${SPRING_DATASOURCE_URL:-}"
    if [ -z "$URL" ] || ! lokal_testdb_antwortet "$URL"; then
        # Lokale DB des Projekts (compose.yaml, Port 5432): start-postgres.sh des Projekts, sonst
        # direkt compose up. Der Exit-Code des Starters ist egal (die Warteschleife unten zaehlt).
        local LOKAL_URL="jdbc:postgresql://localhost:${LOKAL_TEST_DB_PORT:-5432}/${DB_NAME:-plaintext}"
        local RUNTIME=""
        command -v podman >/dev/null 2>&1 && RUNTIME=podman
        [ -z "$RUNTIME" ] && command -v docker >/dev/null 2>&1 && RUNTIME=docker
        if ! lokal_testdb_antwortet "$LOKAL_URL"; then
            if [ -x "./start-postgres.sh" ]; then
                echo -e "${BLUE}Tests: starte lokale DB (./start-postgres.sh)...${NC}"
                ./start-postgres.sh >/dev/null 2>&1 || true
            elif [ -n "$RUNTIME" ] && [ -f "./compose.yaml" ]; then
                echo -e "${BLUE}Tests: starte lokale DB (${RUNTIME} compose up -d)...${NC}"
                $RUNTIME compose up -d >/dev/null 2>&1 || true
            fi
            local I
            for I in $(seq 1 20); do
                lokal_testdb_antwortet "$LOKAL_URL" && break
                sleep 3
            done
        fi
        if lokal_testdb_antwortet "$LOKAL_URL"; then
            # Port offen heisst noch nicht bereit: pg_isready im Container, wenn wir ihn finden.
            if [ -n "$RUNTIME" ]; then
                local C
                C=$($RUNTIME ps --format '{{.Names}}' 2>/dev/null | grep -i postgres | head -1)
                if [ -n "$C" ]; then
                    for I in $(seq 1 20); do
                        $RUNTIME exec "$C" pg_isready -U "${DB_NAME:-plaintext}" >/dev/null 2>&1 && break
                        sleep 3
                    done
                fi
            fi
            URL="$LOKAL_URL"
        fi
    fi
    if [ -n "$URL" ] && lokal_testdb_antwortet "$URL"; then
        export SPRING_DATASOURCE_URL="$URL"
        export MVN_TEST_FLAG="-DskipITs -DexcludedGroups=quality-gate"
        echo -e "${GREEN}✓ Test-DB erreichbar (${URL}) — Unit-Tests laufen im Release-Build (${MVN_TEST_FLAG})${NC}"
        return 0
    fi
    export MVN_TEST_FLAG="-DskipTests"
    echo -e "${RED}⚠⚠ KEINE Test-DB erreichbar — der Release-Build laeuft OHNE Tests (-DskipTests).${NC}"
    echo -e "${YELLOW}   Abhilfe: SPRING_DATASOURCE_URL=jdbc:postgresql://host:port/db setzen oder ./start-postgres.sh im Projekt bereitstellen.${NC}"
    return 0
}

# Blockiert, solange in diesem Repo ein CI-Lauf auf dem Release-Branch aktiv ist: der wuerde
# dieselben NAS-Slots und dasselbe Staging-Jar anfassen. PR-/Branch-Laeufe (GitHub-Runner,
# ci-only) sind unkritisch und werden nur angezeigt. Ohne `gh` oder ohne Netz: Warnung, kein
# Abbruch — ein spaeterer `git push` scheitert dann ohnehin, bevor etwas veroeffentlicht ist.
lokal_release_ci_frei() {
    local BRANCH="${1:-master}"
    if [ "${LOKAL_RELEASE_IGNORIERE_CI:-false}" == "true" ]; then
        echo -e "${YELLOW}⚠ CI-Pruefung uebersprungen (LOKAL_RELEASE_IGNORIERE_CI=true).${NC}"
        return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠ 'gh' nicht installiert — laufende CI-Rollouts koennen nicht geprueft werden.${NC}"
        return 0
    fi
    local REPO
    REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#^.*[:/]([^/]+/[^/]+)$#\1#; s#\.git$##')
    if [ -z "$REPO" ]; then
        echo -e "${YELLOW}⚠ origin-Repository nicht ermittelbar — CI-Pruefung uebersprungen.${NC}"
        return 0
    fi
    echo -e "${BLUE}CI: aktive Laeufe in ${REPO} pruefen...${NC}"
    local LAEUFE
    if ! LAEUFE=$( { gh run list -R "$REPO" --status in_progress --limit 30 --json databaseId,name,headBranch,event,displayTitle \
                        --jq '.[] | "\(.databaseId)\t\(.headBranch)\t\(.event)\t\(.name)\t\(.displayTitle)"';
                     gh run list -R "$REPO" --status queued --limit 30 --json databaseId,name,headBranch,event,displayTitle \
                        --jq '.[] | "\(.databaseId)\t\(.headBranch)\t\(.event)\t\(.name)\t\(.displayTitle)"'; } 2>/dev/null ); then
        echo -e "${YELLOW}⚠ gh run list fehlgeschlagen (Netz/Auth?) — CI-Pruefung uebersprungen.${NC}"
        return 0
    fi
    if [ -z "$LAEUFE" ]; then
        echo -e "${GREEN}✓ Keine CI-Laeufe aktiv${NC}"
        return 0
    fi
    # Massnahme 5 (29.08.2026): der eigene Release-Push loest auf master einen Lauf aus, der wegen
    # "[skip-ci]" im Betreff sofort endet — der blockierte frueher den EIGENEN Deploy. Kritisch sind
    # nur Laeufe des Deploy-Workflows (Name passt auf DEPLOY_WORKFLOW_MUSTER) ohne [skip-ci].
    local KRITISCH
    KRITISCH=$(printf '%s\n' "$LAEUFE" | awk -F'\t' -v b="$BRANCH" -v m="${DEPLOY_WORKFLOW_MUSTER:-[Dd]eploy|[Rr]elease}" \
        '($2 == b || $3 == "workflow_dispatch" || $3 == "schedule") && $4 ~ m && index($5, "[skip-ci]") == 0')
    if [ -n "$KRITISCH" ]; then
        echo -e "${RED}✗ CI-Lauf auf ${BRANCH} aktiv — ein lokaler Deploy wuerde mit ihm kollidieren:${NC}"
        printf '%s\n' "$KRITISCH" | awk -F'\t' '{printf "    run %s  [%s, %s]  %s\n", $1, $2, $3, $4}'
        echo -e "${YELLOW}  Warten (gh run watch <id> -R ${REPO}) oder bewusst: LOKAL_RELEASE_IGNORIERE_CI=true${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ Nur Branch-/PR-/[skip-ci]-Laeufe aktiv (kollidieren nicht mit dem NAS):${NC}"
    printf '%s\n' "$LAEUFE" | awk -F'\t' '{printf "    run %s  [%s, %s]  %s\n", $1, $2, $3, $4}'
    return 0
}

# MVN_RELEASE_DEPLOY=true verlangt Zugangsdaten fuer die server-id aus <distributionManagement>
# (Reposilite, maven.plaintext.ch). Fehlen sie in der settings.xml, scheiterte `mvn deploy` erst
# NACH Tag+Push. Dann lieber nur bauen: das Artefakt geht nicht ins Release-Repo, Tag, Commit
# und Container-Deploy sind davon unabhaengig (die Kollisionspruefung im CI kennt die Version
# dann nicht — sie rechnet ohnehin aus der POM von master weiter).
lokal_release_maven_zugangsdaten() {
    if [ "${MVN_RELEASE_DEPLOY:-false}" != "true" ]; then
        return 0
    fi
    local REPO_ID
    REPO_ID=$(mvn -q -N help:evaluate -Dexpression=project.distributionManagement.repository.id -DforceStdout 2>/dev/null)
    if [ -z "$REPO_ID" ] || [ "$REPO_ID" == "null object or invalid expression" ]; then
        REPO_ID=$(sed -n '/<distributionManagement>/,/<\/distributionManagement>/p' pom.xml 2>/dev/null \
            | grep -m1 '<id>' | sed 's/.*<id>//;s/<\/id>.*//' | tr -d ' ')
    fi
    local SETTINGS="${MAVEN_SETTINGS:-$HOME/.m2/settings.xml}"
    if [ -n "$REPO_ID" ] && grep -q "<id>[[:space:]]*${REPO_ID}[[:space:]]*</id>" "$SETTINGS" 2>/dev/null; then
        # Vorhanden reicht nicht — der Token muss auch GELTEN. Am 29.08.2026 lief ein Lokal-Release
        # mit einem veralteten Reposilite-Token bis nach Commit+Tag+Push und starb erst im
        # `mvn deploy` (401): Tag 2.1709.0 ohne Artefakt. Darum hier ein Probe-Login gegen
        # Reposilite (/api/auth/me), bevor irgendetwas unumkehrbar wird.
        local REPO_URL AUTH_URL USER PASS CODE
        REPO_URL=$(sed -n '/<distributionManagement>/,/<\/distributionManagement>/p' pom.xml 2>/dev/null \
            | grep -m1 '<url>' | sed 's/.*<url>//;s/<\/url>.*//' | tr -d ' ')
        USER=$(awk -v id="$REPO_ID" 'BEGIN{RS="</server>"} $0 ~ "<id>[[:space:]]*"id"[[:space:]]*</id>" {match($0,/<username>[^<]*<\/username>/); print substr($0,RSTART+10,RLENGTH-21); exit}' "$SETTINGS")
        PASS=$(awk -v id="$REPO_ID" 'BEGIN{RS="</server>"} $0 ~ "<id>[[:space:]]*"id"[[:space:]]*</id>" {match($0,/<password>[^<]*<\/password>/); print substr($0,RSTART+10,RLENGTH-21); exit}' "$SETTINGS")
        if [[ "$REPO_URL" =~ ^https?://[^/]+ ]] && [ -n "$USER" ] && [ -n "$PASS" ]; then
            AUTH_URL="${BASH_REMATCH[0]}/api/auth/me"
            CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -u "${USER}:${PASS}" "$AUTH_URL" 2>/dev/null || echo 000)
            case "$CODE" in
                200) echo -e "${GREEN}✓ Maven: Zugangsdaten fuer '${REPO_ID}' gueltig (${AUTH_URL} -> 200) — Artefakt wird veroeffentlicht.${NC}"; return 0 ;;
                401|403)
                    echo -e "${RED}✗ Maven: Zugangsdaten fuer '${REPO_ID}' in ${SETTINGS} werden abgelehnt (${AUTH_URL} -> ${CODE}).${NC}"
                    echo -e "${RED}  Abbruch VOR Commit/Tag — sonst entsteht ein Release-Tag ohne Artefakt.${NC}"
                    echo -e "${YELLOW}  Gueltiger Token: REPOSILITE_OPTS des reposilite-Containers auf dem NAS bzw. Vault 'Reposilite CI-Token (maven.plaintext.ch)'.${NC}"
                    return 1 ;;
                *)   echo -e "${YELLOW}⚠ Maven: Probe-Login gegen ${AUTH_URL} nicht moeglich (HTTP ${CODE}) — Zugangsdaten unverifiziert, Veroeffentlichung wird versucht.${NC}"; return 0 ;;
            esac
        fi
        echo -e "${GREEN}✓ Maven: Zugangsdaten fuer '${REPO_ID}' in ${SETTINGS} vorhanden — Artefakt wird veroeffentlicht.${NC}"
        return 0
    fi
    echo -e "${YELLOW}⚠ Maven: keine Zugangsdaten fuer '${REPO_ID:-<distributionManagement>}' in ${SETTINGS}.${NC}"
    echo -e "${YELLOW}  Es wird nur gebaut (mvn package), das Artefakt geht NICHT ins Release-Repo.${NC}"
    echo -e "${YELLOW}  Fuer Gleichstand mit der CI in ${SETTINGS} eintragen:${NC}"
    echo -e "${YELLOW}    <server><id>${REPO_ID:-plaintext-nas}</id><username>ci</username><password>Reposilite CI-Token (Vault)</password></server>${NC}"
    MVN_RELEASE_DEPLOY=false
    return 0
}

# Nach einem Abbruch in do_release: Ist der Release-Commit NICHT auf origin angekommen, dann
# lokalen Commit und Tag zuruecknehmen — der Zustand ist danach exakt der von vor dem Lauf und
# der naechste Versuch rechnet dieselbe Nummer. Ist der Commit schon draussen (Abbruch spaeter,
# z.B. im Maven-Build), bleibt alles stehen: die Nummer ist verbraucht, der naechste Lauf
# rechnet korrekt weiter (siehe Karte 518 in do_release).
lokal_release_rueckbau() {
    local START_SHA="$1"
    local BRANCH="${2:-master}"
    local V="${NEW_VERSION:-}"
    [ -n "$V" ] || return 0
    if git merge-base --is-ancestor HEAD "origin/${BRANCH}" 2>/dev/null; then
        echo -e "${YELLOW}Release-Commit ${V} ist auf origin — nichts zurueckzunehmen; naechster Lauf rechnet weiter.${NC}"
        return 0
    fi
    if [ "$(git rev-parse HEAD)" == "$START_SHA" ]; then
        # Abbruch vor dem Commit (z.B. Kollisionspruefung) — es gibt nichts zurueckzubauen.
        git tag -d "$V" >/dev/null 2>&1 || true
        return 0
    fi
    echo -e "${YELLOW}Release-Commit ${V} ist NICHT auf origin — nehme lokalen Commit und Tag zurueck...${NC}"
    git tag -d "$V" >/dev/null 2>&1 || true
    if git reset -q --hard "$START_SHA"; then
        echo -e "${GREEN}✓ Zurueck auf $(git log --oneline -1) — der Lauf kann wiederholt werden.${NC}"
    else
        echo -e "${RED}✗ git reset --hard ${START_SHA} fehlgeschlagen — bitte manuell pruefen.${NC}"
    fi
}

# Pushover, best effort: Zugangsdaten kommen aus der Umgebung oder ~/.pushover (siehe ./pushover).
# Ohne Zugangsdaten passiert nichts — ein fehlender Kanal darf den Release nicht rot faerben.
lokal_release_melde() {
    local STATUS="$1"
    local TEXT="$2"
    local PO="${SCRIPTS_DIR}/pushover"
    [ -x "$PO" ] || return 0
    if [ "$STATUS" == "0" ]; then
        "$PO" -p 0 -t "Lokal-Release ${IMAGE_NAME}" "$TEXT" >/dev/null 2>&1 || true
    else
        "$PO" -p 1 -t "Lokal-Release ${IMAGE_NAME} FEHLGESCHLAGEN" "$TEXT" >/dev/null 2>&1 || true
    fi
    return 0
}

# ── SonarQube Analysis ──────────────────────────────────────
do_sonar() {
    echo -e "${YELLOW}=== SonarQube Analysis ===${NC}"

    local SONAR_HOST_URL="${SONAR_HOST_URL:-http://192.168.1.224:9000}"

    # Derive project key from Maven coordinates
    local GROUP_ID
    GROUP_ID=$(mvn help:evaluate -Dexpression=project.groupId -q -DforceStdout 2>/dev/null)
    local ARTIFACT_ID
    ARTIFACT_ID=$(mvn help:evaluate -Dexpression=project.artifactId -q -DforceStdout 2>/dev/null)
    local PROJECT_KEY="${GROUP_ID}:${ARTIFACT_ID}"
    local PROJECT_NAME="${IMAGE_NAME}"
    local PROJECT_VERSION
    PROJECT_VERSION=$(get_pom_version)

    # Check SonarQube server
    echo -e "${BLUE}Checking SonarQube at ${SONAR_HOST_URL}...${NC}"
    if ! curl -s -o /dev/null -w "%{http_code}" "$SONAR_HOST_URL/api/system/status" | grep -q "200"; then
        echo -e "${RED}✗ SonarQube server not reachable at ${SONAR_HOST_URL}${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ SonarQube server is running${NC}"

    # Load token from project config, env var, or plaintext-config
    local SONAR_TOKEN="${SONAR_TOKEN:-}"
    if [ -z "$SONAR_TOKEN" ]; then
        local TOKEN_LOCATIONS=(
            "${SCRIPT_DIR}/config/sonarqube/token.txt"
            "${PLAINTEXT_CONFIG_DIR:-$HOME/codeplain/plaintext-config}/${IMAGE_NAME}/sonar-token.txt"
        )
        for TOKEN_FILE in "${TOKEN_LOCATIONS[@]}"; do
            if [ -f "$TOKEN_FILE" ]; then
                SONAR_TOKEN=$(cat "$TOKEN_FILE" | tr -d '\r\n')
                echo -e "${GREEN}✓ Token loaded from ${TOKEN_FILE}${NC}"
                break
            fi
        done
    fi

    local AUTH_PARAMS=""
    if [ -n "$SONAR_TOKEN" ]; then
        AUTH_PARAMS="-Dsonar.token=$SONAR_TOKEN"
        echo -e "${GREEN}✓ Using token authentication${NC}"
    else
        echo -e "${YELLOW}⚠ No SonarQube token found, trying without auth${NC}"
    fi

    echo -e "${BLUE}Project: ${PROJECT_KEY} (${PROJECT_VERSION})${NC}"
    echo -e "${BLUE}Running SonarQube analysis...${NC}"

    # -Pcoverage erzeugt Jacoco-Coverage für Sonar; -DskipITs überspringt die ITs (brauchen laufende App).
    mvn clean verify sonar:sonar -Pcoverage -DskipITs \
        -Dsonar.projectKey="$PROJECT_KEY" \
        -Dsonar.projectName="$PROJECT_NAME" \
        -Dsonar.projectVersion="$PROJECT_VERSION" \
        -Dsonar.host.url="$SONAR_HOST_URL" \
        -Dsonar.java.source=25 \
        -Dsonar.java.target=25 \
        -Dsonar.scm.provider=git \
        $AUTH_PARAMS \
        -B

    local EXIT_CODE=$?
    if [ $EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ SonarQube analysis completed!${NC}"
        echo -e "${GREEN}Dashboard: ${SONAR_HOST_URL}/dashboard?id=${PROJECT_KEY}${NC}"
    else
        echo -e "${RED}✗ SonarQube analysis failed${NC}"
    fi
    return $EXIT_CODE
}
