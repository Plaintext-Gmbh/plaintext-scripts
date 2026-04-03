#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Common Functions (shared via plaintext-scripts)
#  Source this file for utility functions.
# ═══════════════════════════════════════════════════════════════

# Smart browser opener - only opens if not in automation mode
# Usage: smart_open_browser "/path/to/report.html"
smart_open_browser() {
    local file_path="$1"

    # Check if we're in automation mode (CLAUDE_AUTO=true or NO_BROWSER=true)
    if [ "${CLAUDE_AUTO}" = "true" ] || [ "${NO_BROWSER}" = "true" ]; then
        echo "Automation mode detected - skipping browser open"
        echo "Report available at: ${file_path}"
        return 0
    fi

    # Check if OPEN_BROWSER is explicitly set to false
    if [ "${OPEN_BROWSER}" = "false" ]; then
        echo "Report available at: ${file_path}"
        return 0
    fi

    # Default behavior: open browser if file exists
    if [ -f "${file_path}" ]; then
        echo "Opening report in browser..."
        open "${file_path}"
    else
        echo "Report file not found: ${file_path}"
        return 1
    fi
}

# Export the function
export -f smart_open_browser

# ── Config Loader ─────────────────────────────────────────────
# Loads build-conf.txt from plaintext-config repo first, falls back to project dir.
# Usage: load_build_conf "/path/to/project"
# Sets: IMAGE_NAME, WEBAPP_MODULE, TUI_TITLE, DB_NAME, etc.
PLAINTEXT_CONFIG_DIR="${PLAINTEXT_CONFIG_DIR:-$HOME/codeplain/plaintext-config}"

load_build_conf() {
    local project_dir="${1:-.}"
    local project_name
    project_name=$(basename "$project_dir")

    local config_file=""

    # 1. Check plaintext-config repo (centralized)
    if [[ -f "$PLAINTEXT_CONFIG_DIR/$project_name/build-conf.txt" ]]; then
        config_file="$PLAINTEXT_CONFIG_DIR/$project_name/build-conf.txt"
    # 2. Fallback: project-local build-conf.txt
    elif [[ -f "$project_dir/build-conf.txt" ]]; then
        config_file="$project_dir/build-conf.txt"
    fi

    if [[ -z "$config_file" ]]; then
        return 1
    fi

    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        value="${value%%#*}"
        value="${value%"${value##*[![:space:]]}"}"
        export "$key"="$value"
    done < "$config_file"

    return 0
}

# Resolve compose.yaml from plaintext-config or project dir
# Usage: get_compose_file "/path/to/project"
# Returns: path to compose.yaml
get_compose_file() {
    local project_dir="${1:-.}"
    local project_name
    project_name=$(basename "$project_dir")

    # 1. plaintext-config repo
    if [[ -f "$PLAINTEXT_CONFIG_DIR/$project_name/compose.yaml" ]]; then
        echo "$PLAINTEXT_CONFIG_DIR/$project_name/compose.yaml"
    elif [[ -f "$PLAINTEXT_CONFIG_DIR/$project_name/docker-compose.yaml" ]]; then
        echo "$PLAINTEXT_CONFIG_DIR/$project_name/docker-compose.yaml"
    # 2. Project-local
    elif [[ -f "$project_dir/compose.yaml" ]]; then
        echo "$project_dir/compose.yaml"
    elif [[ -f "$project_dir/docker-compose.yaml" ]]; then
        echo "$project_dir/docker-compose.yaml"
    fi
}

# Resolve deploy dir from plaintext-config or project dir
# Usage: get_deploy_dir "/path/to/project"
# Returns: path to deploy directory
get_deploy_dir() {
    local project_dir="${1:-.}"
    local project_name
    project_name=$(basename "$project_dir")

    # 1. plaintext-config repo
    if [[ -d "$PLAINTEXT_CONFIG_DIR/$project_name/deploy" ]]; then
        echo "$PLAINTEXT_CONFIG_DIR/$project_name/deploy"
    # 2. Project-local fallback
    elif [[ -d "$project_dir/deploy" ]]; then
        echo "$project_dir/deploy"
    fi
}

export -f load_build_conf
export -f get_compose_file
export -f get_deploy_dir
