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
    ssh "${DEPLOY_SERVER}" "mkdir -p ${STAGING}"
    if ! cat "${JAR}" | ssh "${DEPLOY_SERVER}" "cat > ${STAGING}/${TMP_NAME} && chmod 644 ${STAGING}/${TMP_NAME} && mv -f ${STAGING}/${TMP_NAME} ${STAGING}/app.jar"; then
        ssh "${DEPLOY_SERVER}" "rm -f ${STAGING}/${TMP_NAME}" 2>/dev/null
        echo -e "${RED}✗ M3: Jar-Transfer auf NAS fehlgeschlagen${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ M3: Jar im Staging (${STAGING}/app.jar)${NC}"
}

# Function to create backup of prod database (PostgreSQL via SSH on NAS)
backup_prod_db() {
    local REMOTE_BACKUP_DIR="${DEPLOY_PATH}/backups"
    local BACKUP_NAME="backup-$(date +%y-%m-%d_%H-%M).sql.gz"
    local REMOTE_BACKUP_PATH="${REMOTE_BACKUP_DIR}/${BACKUP_NAME}"

    echo -e "${BLUE}=== Creating database backup ===${NC}" >&2
    echo -e "${BLUE}Backup location: ${GREEN}${REMOTE_BACKUP_PATH}${NC}" >&2

    # Create backup directory and run pg_dump via docker exec
    ssh ${DEPLOY_SERVER} "mkdir -p '${REMOTE_BACKUP_DIR}' && \
        sudo docker exec ${DB_CONTAINER_PREFIX:-${IMAGE_NAME}}-db-prod pg_dump -U plaintext ${DB_NAME:-${IMAGE_NAME}} | gzip > '${REMOTE_BACKUP_PATH}'"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Database backup created: ${BACKUP_NAME}${NC}" >&2
        echo "${REMOTE_BACKUP_PATH}"
        return 0
    else
        echo -e "${RED}✗ Database backup failed!${NC}" >&2
        return 1
    fi
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

    echo -e "${BLUE}Switching ${ENV_NAME} to ${NEW_COLOR}...${NC}"

    # Defensiv: vorherige upstream-Config sichern, neue einspielen und mit `nginx -t` PRÜFEN, BEVOR
    # Marker gesetzt + reloaded wird. Zeigt der neue Upstream auf einen nicht (mehr) existierenden
    # Container (z. B. Rollback auf einen bereits gestoppten Slot), schlägt `nginx -t` fehl ->
    # wir stellen die vorherige Config wieder her und ändern weder Marker noch laufende nginx-Config.
    # So bleibt nie eine kaputte conf liegen (die sonst den nächsten Reload/Reboot des GESAMTEN
    # nginx inkl. PROD verhindern würde).
    ssh ${DEPLOY_SERVER} "
        cp ${BG_NGINX_CONF_DIR}/${ENV_NAME}-upstream.conf /tmp/${ENV_NAME}-upstream.conf.bak 2>/dev/null || true
        cp ${BG_NGINX_TEMPLATES_DIR}/${ENV_NAME}-${NEW_COLOR}.conf ${BG_NGINX_CONF_DIR}/${ENV_NAME}-upstream.conf || exit 1
        if sudo docker exec ${BG_NGINX_CONTAINER} nginx -t; then
            echo '${NEW_COLOR}' > ${DEPLOY_PATH}/active-${ENV_NAME}
            sudo docker exec ${BG_NGINX_CONTAINER} nginx -s reload
        else
            echo 'nginx -t fehlgeschlagen - stelle vorherige upstream-Config wieder her, Marker unveraendert'
            cp /tmp/${ENV_NAME}-upstream.conf.bak ${BG_NGINX_CONF_DIR}/${ENV_NAME}-upstream.conf 2>/dev/null || true
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
                ssh ${DEPLOY_SERVER} "sudo docker logs --tail 60 ${CONTAINER_NAME} 2>&1 | tail -60"
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

    echo -e "${RED}✗ Health check failed after ${MAX_WAIT}s!${NC}"
    return 1
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
    if ! check_container_health "$CONTAINER_NAME" "$IMAGE_TAG"; then
        echo -e "${RED}✗ Health check failed on ${CONTAINER_NAME}!${NC}"
        echo -e "${YELLOW}Active slot (${ACTIVE_SLOT}) remains unchanged. No traffic switched.${NC}"
        return 1
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
stop_slot() {
    local ENV_NAME="$1"
    local SLOT="$2"
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
check_version() {
    local EXPECTED_VERSION=$1
    local VERSION_URL=${2:-"http://${NAS_HOST}:${DEV_PORT:-1121}/nosec/version"}
    local MAX_WAIT=120
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
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$VERSION_URL" 2>/dev/null || echo "000")

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
    return 1
}

# Function to deploy to dev server (blue-green)
deploy_to_dev() {
    local IMAGE_TAG=$1
    local WITH_HEALTH_CHECK=${2:-false}

    echo -e "${BLUE}=== Deploying to DEV Server (Blue-Green) ===${NC}"

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

    # Externer Check ok (oder nicht gefordert): JETZT erst den alten Slot stoppen.
    stop_slot "int" "$OLD_SLOT"

    # Erfolgreicher, extern bestätigter INT-Deploy: Migrationsstand-Marker aktualisieren (best effort).
    write_migration_marker "int"

    echo -e "${GREEN}=== DEV Deployment completed! ===${NC}"
    return 0
}

# Function to deploy to prod server (blue-green)
deploy_to_prod() {
    local WITH_HEALTH_CHECK=${1:-false}

    echo -e "${BLUE}=== Deploying to PROD Server (Blue-Green) ===${NC}"

    # Ensure NAS is reachable
    if ! ensure_nas_reachable; then
        echo -e "${RED}✗ Cannot deploy - NAS not reachable${NC}"
        return 1
    fi

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

    # Database backup
    echo ""
    BACKUP_PATH=$(backup_prod_db)
    BACKUP_RESULT=$?

    if [ $BACKUP_RESULT -ne 0 ]; then
        echo -e "${RED}=== Database backup failed! Aborting deployment. ===${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ Backup created: $(basename $BACKUP_PATH)${NC}"
    echo ""

    # Deploy to inactive PROD slot
    if ! deploy_blue_green "prod" "$RELEASE_VERSION"; then
        echo -e "${RED}=== PROD Blue-Green Deployment FAILED ===${NC}"
        echo -e "${YELLOW}Active slot (${ACTIVE_SLOT}) unchanged (Traffic).${NC}"
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
        echo -e "${GREEN}Backup available at: $(basename $BACKUP_PATH)${NC}"
        return 1
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
                echo -e "${YELLOW}DB backup available at: $(basename $BACKUP_PATH)${NC}"
                echo -e "${YELLOW}(Guard umgehen: MIGRATION_GUARD_STRICT=false ändert nichts hier; für erzwungenen Blind-Rollback manuell switch_active nutzen.)${NC}"
                return 1
            fi

            echo -e "${YELLOW}=== Instant rollback: nginx zurück auf ${ACTIVE_SLOT} (läuft noch) ===${NC}"

            switch_active "prod" "$ACTIVE_SLOT"

            # Fehlgeschlagenen neuen Slot stoppen (keine zwei Instanzen auf derselben DB).
            local NEW_SLOT
            if [ "$ACTIVE_SLOT" == "blue" ]; then NEW_SLOT="green"; else NEW_SLOT="blue"; fi
            stop_slot "prod" "$NEW_SLOT"

            echo -e "${YELLOW}=== ROLLBACK COMPLETED ===${NC}"
            echo -e "${YELLOW}PROD back on ${ACTIVE_SLOT}${NC}"
            echo -e "${YELLOW}DB backup available at: $(basename $BACKUP_PATH)${NC}"
            echo -e "${YELLOW}For DB restore: restore_prod_db '${BACKUP_PATH}'${NC}"
            return 1
        fi
    fi

    # Externer Check ok (oder nicht gefordert): JETZT erst den alten Slot stoppen.
    stop_slot "prod" "$ACTIVE_SLOT"

    # Erfolgreicher, extern bestätigter Deploy: aktuellen DB-Migrationsstand als "letzter guter" Marker
    # festhalten (dient dem Rollback-Guard des NÄCHSTEN Deploys). Best effort.
    write_migration_marker "prod"

    echo -e "${GREEN}=== PROD Deployment completed! ===${NC}"
    echo -e "${GREEN}Deployed version: ${RELEASE_VERSION}${NC}"
    echo -e "${GREEN}Backup available at: $(basename $BACKUP_PATH)${NC}"
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
    if ! check_version "latest" "http://${NAS_HOST}:${PROD_PORT:-1142}/nosec/version"; then
        echo -e "${RED}=== Single-PROD-Healthcheck FEHLGESCHLAGEN ===${NC}"
        return 1
    fi
    echo -e "${GREEN}=== Single-PROD-Deploy abgeschlossen ===${NC}"
    return 0
}

# Release build, $1=increment type or deploy flag, $2=optional deploy flag
do_release() {
    echo -e "${YELLOW}=== Release Build ===${NC}"

    CLEAN_VERSION="${CURRENT_VERSION%-SNAPSHOT}"

    IFS='.' read -r -a VERSION_PARTS <<< "$CLEAN_VERSION"
    MAJOR="${VERSION_PARTS[0]}"
    MINOR="${VERSION_PARTS[1]}"
    PATCH="${VERSION_PARTS[2]}"

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
        1)
            MAJOR=$((MAJOR + 1))
            MINOR=0
            PATCH=0
            echo -e "${YELLOW}Incrementing MAJOR version${NC}"
            ;;
        2)
            MINOR=$((MINOR + 1))
            PATCH=0
            echo -e "${YELLOW}Incrementing MINOR version (default)${NC}"
            ;;
        3)
            PATCH=$((PATCH + 1))
            echo -e "${YELLOW}Incrementing PATCH version${NC}"
            ;;
    esac

    NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
    echo -e "${BLUE}New release version: ${GREEN}${NEW_VERSION}${NC}"

    NEXT_MINOR=$((MINOR + 1))
    NEXT_SNAPSHOT_VERSION="${MAJOR}.${NEXT_MINOR}.0-SNAPSHOT"
    echo -e "${BLUE}Next SNAPSHOT version: ${GREEN}${NEXT_SNAPSHOT_VERSION}${NC}"

    echo -e "${BLUE}Maven: Setting version to ${GREEN}${NEW_VERSION}${NC}"
    mvn versions:set -DnewVersion="${NEW_VERSION}" -DgenerateBackupPoms=false

    echo -e "${BLUE}Git: Checking for changes to include in release ${NEW_VERSION}...${NC}"

    echo -e "${YELLOW}Current git status:${NC}"
    git --no-pager status --short

    echo -e "${BLUE}Git: Adding all changes for release commit...${NC}"
    git add -A || true

    echo -e "${YELLOW}Changes to be committed:${NC}"
    git --no-pager diff --cached --name-status || echo "No changes"

    COMMIT_MSG="Release version ${NEW_VERSION}

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

    echo -e "${BLUE}Git: Pushing to remote...${NC}"
    git push
    git push --tags

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
