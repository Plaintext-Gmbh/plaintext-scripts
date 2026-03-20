#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Stop PostgreSQL - Generic version (shared via plaintext-scripts)
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
            DB_CONTAINER_PREFIX) DB_CONTAINER_PREFIX="$value" ;;
        esac
    done < "$SCRIPT_DIR/build-conf.txt"
fi

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

# ── Stop PostgreSQL ──────────────────────────────────────────
echo "=== PostgreSQL Container stoppen (${RUNTIME}) ==="

if [[ -f "$SCRIPT_DIR/compose.yaml" ]]; then
    $RUNTIME compose down
elif [[ -f "$SCRIPT_DIR/docker-compose.yaml" ]]; then
    $RUNTIME compose -f "$SCRIPT_DIR/docker-compose.yaml" down
elif [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    $RUNTIME compose -f "$SCRIPT_DIR/docker-compose.yml" down
else
    # Fallback: try to stop containers by name
    echo "Kein Compose-File gefunden, versuche Container direkt zu stoppen..."
    CONTAINERS=$($RUNTIME ps --format '{{.Names}}' 2>/dev/null | grep -i "${DB_CONTAINER_PREFIX}.*postgres" || true)
    if [[ -n "$CONTAINERS" ]]; then
        echo "$CONTAINERS" | while read -r c; do
            $RUNTIME stop "$c" 2>/dev/null || true
            $RUNTIME rm "$c" 2>/dev/null || true
            echo "Container $c gestoppt"
        done
    else
        echo "Keine laufenden PostgreSQL-Container gefunden"
    fi
    exit 0
fi

echo "PostgreSQL Container gestoppt!"
