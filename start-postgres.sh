#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Start PostgreSQL - Generic version (shared via plaintext-scripts)
#  Reads DB settings from build-conf.txt in the project root.
#  Supports both podman and docker.
# ═══════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ── Load config from build-conf.txt ──────────────────────────
if [[ -f "$SCRIPT_DIR/build-conf.txt" ]]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        value="${value%%#*}"
        value="${value%"${value##*[![:space:]]}"}"
        case "$key" in
            DB_NAME) DB_NAME="$value" ;;
            DB_CONTAINER_PREFIX) DB_CONTAINER_PREFIX="$value" ;;
        esac
    done < "$SCRIPT_DIR/build-conf.txt"
fi

DB_NAME="${DB_NAME:-plaintext}"
DB_CONTAINER_PREFIX="${DB_CONTAINER_PREFIX:-plaintext}"

# ── Detect container runtime ─────────────────────────────────
if command -v podman &>/dev/null; then
    RUNTIME="podman"
elif command -v docker &>/dev/null; then
    RUNTIME="docker"
else
    echo "ERROR: Neither podman nor docker found!"
    exit 1
fi

# ── Start PostgreSQL ─────────────────────────────────────────
echo "=== PostgreSQL Container starten (${RUNTIME}) ==="

if [[ -f "$SCRIPT_DIR/compose.yaml" ]]; then
    $RUNTIME compose up -d
elif [[ -f "$SCRIPT_DIR/docker-compose.yaml" ]]; then
    $RUNTIME compose -f "$SCRIPT_DIR/docker-compose.yaml" up -d
elif [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    $RUNTIME compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
else
    echo "ERROR: No compose file found (compose.yaml / docker-compose.yaml)"
    exit 1
fi

echo "=== Warte auf PostgreSQL... ==="
for i in $(seq 1 30); do
    # Try to find the postgres container by prefix
    CONTAINER=$($RUNTIME ps --format '{{.Names}}' 2>/dev/null | grep -i "${DB_CONTAINER_PREFIX}.*postgres" | head -1)
    if [[ -z "$CONTAINER" ]]; then
        CONTAINER=$($RUNTIME ps --format '{{.Names}}' 2>/dev/null | grep -i "postgres" | head -1)
    fi

    if [[ -n "$CONTAINER" ]]; then
        if $RUNTIME exec "$CONTAINER" pg_isready -U "${DB_NAME}" > /dev/null 2>&1; then
            echo "PostgreSQL ist bereit! (Container: $CONTAINER)"
            exit 0
        fi
    fi

    if [ "$i" -eq 30 ]; then
        echo "FEHLER: PostgreSQL nicht bereit nach 30 Sekunden"
        exit 1
    fi
    sleep 1
done
