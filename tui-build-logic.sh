#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Build Logic Library (shared via plaintext-scripts)
#  Business logic for build, release, deploy, and version mgmt.
#  Sourced by: build
#  Requires: tui-common.sh, build-conf.txt loaded
#  Expects: SCRIPT_DIR set, cwd = SCRIPT_DIR
# ═══════════════════════════════════════════════════════════════

# ── Load project configuration from build-conf.txt ───────────
if [ -f "$SCRIPT_DIR/build-conf.txt" ]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        value="${value%%#*}"
        value="${value%"${value##*[![:space:]]}"}"
        export "$key"="$value"
    done < "$SCRIPT_DIR/build-conf.txt"
else
    echo "ERROR: build-conf.txt not found in $SCRIPT_DIR" >&2
    exit 1
fi

# Validate required config
: "${IMAGE_NAME:?IMAGE_NAME must be set in build-conf.txt}"
: "${WEBAPP_MODULE:?WEBAPP_MODULE must be set in build-conf.txt}"
: "${TUI_TITLE:?TUI_TITLE must be set in build-conf.txt}"

# Auto-detect container runtime (podman on macOS, docker on Linux)
if [ -f "/opt/homebrew/bin/podman" ]; then
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
VERSION_FILE="version.txt"
VERSION_RELEASE_FILE="versionRelease.txt"
DEPLOY_SERVER="mad@${NAS_HOST}"
DEPLOY_PATH="${DEPLOY_PATH:-/volume1/docker/${IMAGE_NAME}}"
COMPOSE_FILE="docker-compose.yaml"

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
    echo -e "${BLUE}Multi-command execution:${NC}"
    echo -e "  ${GREEN}./build 56${NC}                 - Execute 5, then 6 (stops on first failure)"
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

# Switch nginx upstream to the specified slot
switch_active() {
    local ENV_NAME="$1"
    local NEW_COLOR="$2"

    echo -e "${BLUE}Switching ${ENV_NAME} to ${NEW_COLOR}...${NC}"

    ssh ${DEPLOY_SERVER} "
        cp ${BG_NGINX_TEMPLATES_DIR}/${ENV_NAME}-${NEW_COLOR}.conf ${BG_NGINX_CONF_DIR}/${ENV_NAME}-upstream.conf && \
        echo '${NEW_COLOR}' > ${DEPLOY_PATH}/active-${ENV_NAME} && \
        sudo docker exec ${BG_NGINX_CONTAINER} nginx -s reload
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
    local MAX_WAIT="${3:-120}"
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

# ── Session Transfer (Blue-Green) ─────────────────────────────

# Export sessions from a running container (non-blocking: returns 0 even on failure)
export_sessions() {
    local CONTAINER="$1"
    local OUTPUT_FILE="$2"

    echo -e "${BLUE}Exporting sessions from ${CONTAINER}...${NC}"

    local RESULT
    RESULT=$(ssh ${DEPLOY_SERVER} "sudo docker exec ${CONTAINER} \
        wget -qO- --header='Authorization: Bearer ${SESSION_TRANSFER_TOKEN}' \
        http://localhost:8080/nosec/root/sessions/export 2>/dev/null" 2>/dev/null) || true

    if [ -z "$RESULT" ] || ! echo "$RESULT" | grep -q '"sessionCount"'; then
        echo -e "${YELLOW}⚠ Session export failed or empty (non-critical, continuing)${NC}"
        echo "" > "$OUTPUT_FILE"
        return 1
    fi

    echo "$RESULT" > "$OUTPUT_FILE"
    local COUNT
    COUNT=$(echo "$RESULT" | grep -o '"sessionCount":[0-9]*' | grep -o '[0-9]*')
    echo -e "${GREEN}✓ Exported ${COUNT:-0} sessions${NC}"
    return 0
}

# Import sessions into a running container (non-blocking: returns 0 even on failure)
import_sessions() {
    local CONTAINER="$1"
    local INPUT_FILE="$2"

    # Skip if export file is empty or missing
    if [ ! -s "$INPUT_FILE" ]; then
        echo -e "${YELLOW}⚠ No session data to import (skipping)${NC}"
        return 0
    fi

    echo -e "${BLUE}Importing sessions to ${CONTAINER}...${NC}"

    # Transfer session data to NAS, copy into container, POST it
    cat "${INPUT_FILE}" | ssh ${DEPLOY_SERVER} "cat > /tmp/sessions-import.json" 2>/dev/null || true

    local RESULT
    RESULT=$(ssh ${DEPLOY_SERVER} "
        sudo docker cp /tmp/sessions-import.json ${CONTAINER}:/tmp/sessions-import.json 2>/dev/null && \
        sudo docker exec ${CONTAINER} wget -qO- \
            --post-file=/tmp/sessions-import.json \
            --header='Authorization: Bearer ${SESSION_TRANSFER_TOKEN}' \
            --header='Content-Type: application/json' \
            http://localhost:8080/nosec/root/sessions/import 2>/dev/null
        sudo docker exec ${CONTAINER} rm -f /tmp/sessions-import.json 2>/dev/null
        rm -f /tmp/sessions-import.json
    " 2>/dev/null) || true

    if echo "$RESULT" | grep -q '"imported"'; then
        local IMPORTED
        IMPORTED=$(echo "$RESULT" | grep -o '"imported":[0-9]*' | grep -o '[0-9]*')
        echo -e "${GREEN}✓ Imported ${IMPORTED:-0} sessions${NC}"
    else
        echo -e "${YELLOW}⚠ Session import failed (non-critical, users may need to re-login)${NC}"
    fi

    return 0
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
    local COMPOSE_SERVICE="${ENV_NAME}-${INACTIVE_SLOT}"

    echo -e "${BLUE}=== Blue-Green Deploy: ${ENV_NAME} ===${NC}"
    echo -e "${BLUE}Active slot:   ${GREEN}${ACTIVE_SLOT}${NC}"
    echo -e "${BLUE}Deploying to:  ${GREEN}${INACTIVE_SLOT}${NC} (${CONTAINER_NAME})"
    echo -e "${BLUE}Image tag:     ${GREEN}${IMAGE_TAG}${NC}"

    # Update image tag for the inactive slot
    echo -e "${BLUE}Updating image for ${COMPOSE_SERVICE}...${NC}"
    ssh ${DEPLOY_SERVER} "cd ${DEPLOY_PATH} && \
        sed -i.backup '/${COMPOSE_SERVICE}:/,/image:/ s|image: ${IMAGE_NAME}:.*|image: ${IMAGE_NAME}:${IMAGE_TAG}|' ${COMPOSE_FILE} && \
        mkdir -p backups && mv ${COMPOSE_FILE}.backup backups/docker-compose-\$(date +%y-%m-%d_%H-%M).yaml"

    # Recreate only the inactive container
    echo -e "${BLUE}Restarting ${COMPOSE_SERVICE} with new image...${NC}"
    ssh ${DEPLOY_SERVER} "cd ${DEPLOY_PATH} && \
        sudo docker compose up -d --no-deps --pull never ${COMPOSE_SERVICE}"

    echo -e "${BLUE}Container status:${NC}"
    ssh ${DEPLOY_SERVER} "sudo docker ps | grep ${CONTAINER_NAME} || echo 'Container not running!'"

    # Health check on the inactive container
    if ! check_container_health "$CONTAINER_NAME" "$IMAGE_TAG"; then
        echo -e "${RED}✗ Health check failed on ${CONTAINER_NAME}!${NC}"
        echo -e "${YELLOW}Active slot (${ACTIVE_SLOT}) remains unchanged. No traffic switched.${NC}"
        return 1
    fi

    # Session transfer: export from active, import to new, THEN switch
    local ACTIVE_CONTAINER="${IMAGE_NAME}-${ENV_NAME}-${ACTIVE_SLOT}"
    if [ -n "${SESSION_TRANSFER_TOKEN}" ]; then
        local SESSION_DUMP="/tmp/session-dump-${IMAGE_NAME}-${ENV_NAME}.json"
        export_sessions "${ACTIVE_CONTAINER}" "${SESSION_DUMP}"
        import_sessions "${CONTAINER_NAME}" "${SESSION_DUMP}"
        rm -f "${SESSION_DUMP}"
    fi

    # Switch nginx to the new slot (sessions are already imported)
    echo -e "${BLUE}Health check passed - switching traffic...${NC}"
    if ! switch_active "$ENV_NAME" "$INACTIVE_SLOT"; then
        echo -e "${RED}✗ Nginx switch failed! Traffic still on ${ACTIVE_SLOT}.${NC}"
        return 1
    fi

    # Stop the old container to avoid two instances on the same DB (and duplicate crons)
    local OLD_SERVICE="${ENV_NAME}-${ACTIVE_SLOT}"
    echo -e "${BLUE}Stopping old container ${ACTIVE_CONTAINER}...${NC}"
    ssh ${DEPLOY_SERVER} "cd ${DEPLOY_PATH} && sudo docker compose stop ${OLD_SERVICE}" 2>/dev/null || true
    echo -e "${GREEN}✓ Old container ${ACTIVE_CONTAINER} stopped${NC}"

    echo -e "${GREEN}=== Blue-Green deploy complete: ${ENV_NAME} now on ${INACTIVE_SLOT} (${IMAGE_TAG}) ===${NC}"
    return 0
}

# One-time setup: deploy blue-green infrastructure to NAS
setup_blue_green() {
    echo -e "${BLUE}=== Setting up Blue-Green deployment on NAS ===${NC}"

    if ! ensure_nas_reachable; then
        echo -e "${RED}✗ Cannot reach NAS${NC}"
        return 1
    fi

    local DEPLOY_DIR="$SCRIPT_DIR/deploy"

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
ensure_nas_reachable() {
    echo -e "${BLUE}Checking NAS connectivity (${NAS_HOST})...${NC}"
    if ssh -o ConnectTimeout=10 "${DEPLOY_SERVER}" "echo ok" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ NAS reachable${NC}"
        return 0
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
            echo -e "${YELLOW}Rolling back: switching to previous slot...${NC}"
            local CURRENT
            CURRENT=$(get_active_slot "int")
            local PREV
            if [ "$CURRENT" == "blue" ]; then PREV="green"; else PREV="blue"; fi
            switch_active "int" "$PREV"
            echo -e "${YELLOW}Rolled back INT to ${PREV}${NC}"
            return 1
        fi
    fi

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

    if [ ! -f "$VERSION_RELEASE_FILE" ]; then
        echo -e "${RED}Error: $VERSION_RELEASE_FILE not found!${NC}"
        echo -e "${RED}No release version available for production deployment.${NC}"
        exit 1
    fi

    local RELEASE_VERSION=$(cat "$VERSION_RELEASE_FILE")
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
        echo -e "${YELLOW}Active slot (${ACTIVE_SLOT}) unchanged. No rollback needed.${NC}"
        echo -e "${GREEN}Backup available at: $(basename $BACKUP_PATH)${NC}"
        return 1
    fi

    # External health check via nginx port
    if [ "$WITH_HEALTH_CHECK" == "true" ]; then
        echo ""
        if ! check_version "$RELEASE_VERSION" "http://${NAS_HOST}:${PROD_PORT:-1122}/nosec/version"; then
            echo -e "${RED}=== PROD external health check FAILED ===${NC}"
            echo -e "${YELLOW}=== Instant rollback: switching nginx back to ${ACTIVE_SLOT} ===${NC}"

            switch_active "prod" "$ACTIVE_SLOT"

            echo -e "${YELLOW}=== ROLLBACK COMPLETED (nginx switch only) ===${NC}"
            echo -e "${YELLOW}PROD back on ${ACTIVE_SLOT}${NC}"
            echo -e "${YELLOW}DB backup available at: $(basename $BACKUP_PATH)${NC}"
            echo -e "${YELLOW}For DB restore: restore_prod_db '${BACKUP_PATH}'${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}=== PROD Deployment completed! ===${NC}"
    echo -e "${GREEN}Deployed version: ${RELEASE_VERSION}${NC}"
    echo -e "${GREEN}Backup available at: $(basename $BACKUP_PATH)${NC}"
    return 0
}

# Function to compare versions and auto-increment if needed
fix_version_mismatch() {
    local version_txt="$1"
    local version_release_txt="$2"

    local current_version=$(cat "$version_txt" 2>/dev/null || echo "1.0.0-SNAPSHOT")
    local release_version=$(cat "$version_release_txt" 2>/dev/null || echo "0.0.0")

    local current_clean="${current_version%-SNAPSHOT}"

    IFS='.' read -r -a current_parts <<< "$current_clean"
    IFS='.' read -r -a release_parts <<< "$release_version"

    local current_major="${current_parts[0]:-0}"
    local current_minor="${current_parts[1]:-0}"
    local current_patch="${current_parts[2]:-0}"

    local release_major="${release_parts[0]:-0}"
    local release_minor="${release_parts[1]:-0}"
    local release_patch="${release_parts[2]:-0}"

    local current_num=$((current_major * 10000 + current_minor * 100 + current_patch))
    local release_num=$((release_major * 10000 + release_minor * 100 + release_patch))

    if [ $release_num -ge $current_num ]; then
        local new_minor=$((release_minor + 1))
        local new_version="${release_major}.${new_minor}.0-SNAPSHOT"

        echo -e "${YELLOW}Version mismatch detected!${NC}" >&2
        echo -e "${YELLOW}  Current version.txt:        ${current_version}${NC}" >&2
        echo -e "${YELLOW}  Release versionRelease.txt: ${release_version}${NC}" >&2
        echo -e "${GREEN}  Auto-correcting to:         ${new_version}${NC}" >&2

        echo "$new_version" > "$version_txt"
        echo "$new_version"
    else
        echo "$current_version"
    fi
}

# ── Version Initialization ────────────────────────────────────

init_versions() {
    if [ ! -f "$VERSION_FILE" ]; then
        echo "1.0.0-SNAPSHOT" > "$VERSION_FILE"
    fi

    VERSION_BEFORE=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")
    CURRENT_VERSION=$(fix_version_mismatch "$VERSION_FILE" "$VERSION_RELEASE_FILE")
    VERSION_AFTER=$(cat "$VERSION_FILE" 2>/dev/null || echo "unknown")

    if [ "$VERSION_BEFORE" != "$VERSION_AFTER" ]; then
        echo -e "${BLUE}Version was auto-corrected, updating Maven POMs...${NC}"

        if ! mvn versions:set -DnewVersion="${CURRENT_VERSION}" -DgenerateBackupPoms=false -q 2>/dev/null; then
            echo -e "${YELLOW}Maven versions:set failed, trying with next minor version...${NC}"

            IFS='.' read -r -a ver_parts <<< "${CURRENT_VERSION%-SNAPSHOT}"
            MAJOR="${ver_parts[0]:-1}"
            MINOR="${ver_parts[1]:-0}"
            NEW_MINOR=$((MINOR + 1))
            FALLBACK_VERSION="${MAJOR}.${NEW_MINOR}.0-SNAPSHOT"

            echo -e "${YELLOW}Fallback version: ${GREEN}${FALLBACK_VERSION}${NC}"
            echo "$FALLBACK_VERSION" > "$VERSION_FILE"
            CURRENT_VERSION="$FALLBACK_VERSION"

            if ! mvn versions:set -DnewVersion="${CURRENT_VERSION}" -DgenerateBackupPoms=false -q 2>/dev/null; then
                echo -e "${RED}Maven versions:set failed even with fallback version!${NC}"
                echo -e "${YELLOW}Continuing anyway with version in pom.xml...${NC}"
            fi
        fi

        echo -e "${BLUE}Committing version correction...${NC}"
        git add "$VERSION_FILE" pom.xml "*/pom.xml" 2>/dev/null || true
        git commit -m "Auto-correct version to ${CURRENT_VERSION} [skip-ci]" || true
    fi

    # Read release version for display
    RELEASE_VERSION=""
    if [ -f "$VERSION_RELEASE_FILE" ]; then
        RELEASE_VERSION=$(cat "$VERSION_RELEASE_FILE")
    fi
}

# ── Workflow Functions ────────────────────────────────────────

# Build + Run locally (no Docker)
do_run() {
    echo -e "${YELLOW}=== Build + Run (local) ===${NC}"

    BUILD_TIME=$(date '+%d.%m.%y %H:%M')
    echo "$BUILD_TIME" > buildTimestamp.txt
    echo -e "${BLUE}Build timestamp: ${GREEN}${BUILD_TIME}${NC}"

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

    BUILD_TIME=$(date '+%d.%m.%y %H:%M')
    echo "$BUILD_TIME" > buildTimestamp.txt
    echo -e "${BLUE}Build timestamp: ${GREEN}${BUILD_TIME}${NC}"

    echo -e "${BLUE}Building with Maven...${NC}"
    if ! mvn clean package -DskipTests; then
        echo -e "${RED}✗ Maven build failed!${NC}"
        return 1
    fi

    ensure_podman_running || return 1

    echo -e "${BLUE}Building Docker image with tag: ${GREEN}latest${NC}"
    if [[ "$CONTAINER_CLI" == *"podman"* ]]; then
        $CONTAINER_CLI build --platform linux/amd64 --format docker -t "${IMAGE_NAME}:latest" .
    else
        $CONTAINER_CLI build --platform linux/amd64 -t "${IMAGE_NAME}:latest" .
    fi

    push_to_registry "latest"

    echo -e "${GREEN}=== Build completed successfully! ===${NC}"

    if [ "$1" == "deploy" ]; then
        deploy_to_dev "latest"
    fi
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

    echo "$NEW_VERSION" > "$VERSION_RELEASE_FILE"

    echo -e "${BLUE}Maven: Setting version to ${GREEN}${NEW_VERSION}${NC}"
    mvn versions:set -DnewVersion="${NEW_VERSION}" -DgenerateBackupPoms=false

    BUILD_TIME=$(date '+%d.%m.%y %H:%M')
    echo "$BUILD_TIME" > buildTimestamp.txt
    echo -e "${BLUE}Build timestamp: ${GREEN}${BUILD_TIME}${NC}"

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

    if [ "${MVN_RELEASE_DEPLOY}" == "true" ]; then
        echo -e "${BLUE}Maven: Building + deploying version ${GREEN}${NEW_VERSION}${NC}"
        if ! mvn clean deploy -DskipTests -B; then
            echo -e "${RED}✗ Maven build failed!${NC}"
            return 1
        fi
    else
        echo -e "${BLUE}Maven: Building version ${GREEN}${NEW_VERSION}${NC}"
        if ! mvn clean package -DskipTests; then
            echo -e "${RED}✗ Maven build failed!${NC}"
            return 1
        fi
    fi

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

    echo -e "${BLUE}Maven: Preparing next SNAPSHOT version ${GREEN}${NEXT_SNAPSHOT_VERSION}${NC}"
    mvn versions:set -DnewVersion="${NEXT_SNAPSHOT_VERSION}" -DgenerateBackupPoms=false

    echo "$NEXT_SNAPSHOT_VERSION" > "$VERSION_FILE"

    echo -e "${BLUE}Git: Committing next SNAPSHOT version...${NC}"
    git add "$VERSION_FILE" pom.xml "*/pom.xml" || true
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
