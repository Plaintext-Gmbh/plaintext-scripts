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
# Karte 30: der statische /autologin?key= ist entfernt. Ohne Token oeffnet der Browser
# schlicht die Loginseite; mit PLAINTEXT_KIOSK_TOKEN (ApiToken-JWT, Scope SESSION) den
# Token-Login — letzteres funktioniert nur gegen Instanzen mit stabilem JWT-Schluessel.
if [ -n "${PLAINTEXT_KIOSK_TOKEN:-}" ]; then
    LOGIN_URL="http://localhost:8080/token-login?token=$PLAINTEXT_KIOSK_TOKEN"
else
    LOGIN_URL="http://localhost:8080/login.html"
fi

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

    (while ! curl -s -o /dev/null http://localhost:8080 2>/dev/null; do sleep 1; done; open "$LOGIN_URL") &

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

# ── Flyway Version Number ─────────────────────────────────────

do_flywaynr() {
    exec "$HOME/codeplain/plaintext-scripts/getflywaynr"
}

# ── Playwright Integration Tests ──────────────────────────────

do_playwright_build() {
    echo -e "${FG_BLUE}${BOLD}Playwright Tests (build + start + test)${RESET}"
    cd "$SCRIPT_DIR"
    local MVN="mvn"
    [[ -f "$SCRIPT_DIR/mvnw" ]] && MVN="$SCRIPT_DIR/mvnw"

    local TEST_PORT=9090
    local APP_PID=""

    cleanup_playwright() {
        if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
            echo -e "${FG_YELLOW}Stopping test app (PID: $APP_PID)...${RESET}"
            kill "$APP_PID" 2>/dev/null || true
            sleep 2
            kill -9 "$APP_PID" 2>/dev/null || true
        fi
    }
    trap cleanup_playwright RETURN

    echo -e "${FG_YELLOW}1. Building project...${RESET}"
    $MVN clean package -DskipTests -q || { echo -e "${FG_RED}Build failed${RESET}"; return 1; }

    echo -e "${FG_YELLOW}2. Starting app on port $TEST_PORT...${RESET}"
    java -jar "$WEBAPP_MODULE/target/"*.jar \
        --server.port=$TEST_PORT \
        --spring.docker.compose.enabled=false \
        > /tmp/playwright-app.log 2>&1 &
    APP_PID=$!

    echo -e "${FG_YELLOW}3. Waiting for app...${RESET}"
    local count=0
    while [[ $count -lt 90 ]]; do
        if curl -s http://localhost:$TEST_PORT/login.xhtml > /dev/null 2>&1; then
            echo -e "${FG_GREEN}App ready!${RESET}"
            break
        fi
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            echo -e "${FG_RED}App crashed! See /tmp/playwright-app.log${RESET}"
            return 1
        fi
        sleep 1
        count=$((count+1))
    done

    if [[ $count -eq 90 ]]; then
        echo -e "${FG_RED}Timeout waiting for app${RESET}"
        return 1
    fi

    echo -e "${FG_YELLOW}4. Running Playwright tests...${RESET}"
    $MVN failsafe:integration-test failsafe:verify \
        -pl "$WEBAPP_MODULE" \
        -Dit.test=PlaywrightPageIT \
        -Dtest.server.port=$TEST_PORT \
        -Dtest.server.url=http://localhost:$TEST_PORT
    local result=$?

    if [[ $result -eq 0 ]]; then
        echo -e "${FG_GREEN}All Playwright tests passed!${RESET}"
    else
        echo -e "${FG_RED}Playwright tests failed!${RESET}"
    fi
    return $result
}

do_playwright_running() {
    echo -e "${FG_BLUE}${BOLD}Playwright Tests (against running app)${RESET}"
    cd "$SCRIPT_DIR"
    local MVN="mvn"
    [[ -f "$SCRIPT_DIR/mvnw" ]] && MVN="$SCRIPT_DIR/mvnw"

    local TEST_PORT=8080

    if ! curl -s http://localhost:$TEST_PORT/login.xhtml > /dev/null 2>&1; then
        echo -e "${FG_RED}App not running on port $TEST_PORT${RESET}"
        return 1
    fi

    echo -e "${FG_YELLOW}Running Playwright tests against localhost:$TEST_PORT...${RESET}"
    $MVN failsafe:integration-test failsafe:verify \
        -pl "$WEBAPP_MODULE" \
        -Dit.test=PlaywrightPageIT \
        -Dtest.server.port=$TEST_PORT \
        -Dtest.server.url=http://localhost:$TEST_PORT
    local result=$?

    if [[ $result -eq 0 ]]; then
        echo -e "${FG_GREEN}All Playwright tests passed!${RESET}"
    else
        echo -e "${FG_RED}Playwright tests failed!${RESET}"
    fi
    return $result
}
