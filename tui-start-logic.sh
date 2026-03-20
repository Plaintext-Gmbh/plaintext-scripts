#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Start Logic - Business logic for the dev runner (shared)
#  Sourced by: start
#  Requires: SCRIPT_DIR set by caller, tui-common.sh sourced,
#            build-conf.txt loaded (WEBAPP_MODULE)
# ═══════════════════════════════════════════════════════════════

: "${WEBAPP_MODULE:?WEBAPP_MODULE must be set in build-conf.txt}"

PID_FILE="$SCRIPT_DIR/.app.pid"
LOG_FILE="$SCRIPT_DIR/app.log"
AUTOLOGIN_URL="${AUTOLOGIN_URL:-http://localhost:8080/autologin?key=AUTOLOGIN_KEY_ENTFERNT_KARTE_468}"

# ── Action functions ─────────────────────────────────────────

do_start() {
    echo -e "${FG_BLUE}${BOLD}Starting application with spring-boot:run...${RESET}"
    cd "$SCRIPT_DIR"

    # Start PostgreSQL container
    if command -v podman &>/dev/null; then
        podman compose up -d 2>/dev/null || true
    elif command -v docker &>/dev/null; then
        docker compose up -d 2>/dev/null || true
    fi

    # Use mvnw if available, otherwise mvn
    local MVN="mvn"
    [[ -f "$SCRIPT_DIR/mvnw" ]] && MVN="$SCRIPT_DIR/mvnw"

    # First install all dependencies, then run only the webapp module
    $MVN install -pl "$WEBAPP_MODULE" -am -DskipTests -q && \
    $MVN spring-boot:run -pl "$WEBAPP_MODULE" -DskipTests > "$LOG_FILE" 2>&1 &
    local PID=$!
    echo "$PID" > "$PID_FILE"

    (while ! curl -s -o /dev/null http://localhost:8080 2>/dev/null; do sleep 1; done; open "$AUTOLOGIN_URL") &

    echo -e "${FG_GREEN}Application started (PID: ${PID})${RESET}"
    echo -e "${FG_DIM}Logs: ${LOG_FILE}${RESET}"
}

do_kill() {
    local killed=false

    # 1) Try PID file first
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 2
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
            killed=true
        fi
        rm -f "$PID_FILE"
    fi

    # 2) Also find any spring-boot:run or JAR process
    local pids
    pids=$(pgrep -f "spring-boot:run.*${WEBAPP_MODULE}" 2>/dev/null || true)
    if [[ -z "$pids" ]]; then
        pids=$(pgrep -f "${WEBAPP_MODULE}.*\.jar" 2>/dev/null || true)
    fi
    if [[ -n "$pids" ]]; then
        echo "$pids" | while read -r p; do
            kill "$p" 2>/dev/null || true
        done
        sleep 2
        # Force kill remaining
        pids=$(pgrep -f "spring-boot:run.*${WEBAPP_MODULE}" 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            echo "$pids" | while read -r p; do
                kill -9 "$p" 2>/dev/null || true
            done
        fi
        killed=true
    fi

    if [[ "$killed" == "true" ]]; then
        echo -e "${FG_RED}Application stopped${RESET}"
    else
        echo -e "${FG_DIM}No running application found${RESET}"
    fi
}

do_clean_install() {
    echo -e "${FG_BLUE}${BOLD}Running mvn clean install...${RESET}"
    cd "$SCRIPT_DIR"
    local MVN="mvn"
    [[ -f "$SCRIPT_DIR/mvnw" ]] && MVN="$SCRIPT_DIR/mvnw"
    $MVN clean install -DskipTests
    echo -e "${FG_GREEN}Clean install completed${RESET}"
}

do_logs() {
    osascript -e "tell application \"Terminal\" to do script \"tail -f ${LOG_FILE}\"" 2>/dev/null || true
    echo -e "${FG_GREEN}Logs opened in new Terminal window${RESET}"
}

get_status_line() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            echo "running (PID: $pid)"
            return
        fi
    fi
    echo "stopped"
}
