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
