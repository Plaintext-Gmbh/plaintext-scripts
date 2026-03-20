#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  TUI Common Library
#  Shared drawing primitives, colors, and terminal management.
#  Sourced by: start, build, modules
# ═══════════════════════════════════════════════════════════════

# ── Colors (Blue Theme) ──────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'
BG_BLUE='\033[44m'
BG_SELECT='\033[48;5;24m'
FG_WHITE='\033[97m'
FG_CYAN='\033[96m'
FG_BLUE='\033[94m'
FG_DBLUE='\033[38;5;69m'
FG_DIM='\033[38;5;243m'
FG_GREEN='\033[92m'
FG_YELLOW='\033[93m'
FG_RED='\033[91m'

# ── Box Width ────────────────────────────────────────────────
TUI_W=50

# ── Positioning State ────────────────────────────────────────
TUI_R=0           # current row (updated by tui_nr)
TUI_C=0           # current column (set by tui_center)
TUI_ORIG_STTY=""

# ── Terminal Management ──────────────────────────────────────

tui_init() {
    TUI_ORIG_STTY=$(stty -g)
    tput civis
    stty -echo
}

tui_cleanup() {
    tput cnorm 2>/dev/null
    stty "$TUI_ORIG_STTY" 2>/dev/null || true
}

# ── Positioning ──────────────────────────────────────────────

# Calculate centering. Sets TUI_R and TUI_C.
# $1 = total box height in lines
tui_center() {
    local total_height="$1"
    local term_rows term_cols
    term_rows=$(tput lines)
    term_cols=$(tput cols)
    TUI_R=$(( (term_rows - total_height) / 2 ))
    [[ $TUI_R -lt 0 ]] && TUI_R=0
    TUI_C=$(( (term_cols - TUI_W - 2) / 2 ))
    [[ $TUI_C -lt 0 ]] && TUI_C=0
    tput cup $TUI_R $TUI_C
}

# Advance to next row
tui_nr() {
    TUI_R=$((TUI_R + 1))
    tput cup $TUI_R $TUI_C
}

# ── Drawing Primitives ───────────────────────────────────────
# All output exactly one line, NO trailing newline.

# Horizontal line: ┌───┐ or ├───┤ or └───┘
tui_hline() {
    local l="$1" m="$2" r="$3"
    printf "${FG_DBLUE}%s" "$l"
    local j; for ((j=0; j<TUI_W; j++)); do printf "%s" "$m"; done
    printf "%s${RESET}" "$r"
}

# Row with box borders: │<text padded>│
# $1=text  $2=ANSI prefix
tui_row() {
    local text="$1" prefix="$2"
    local tlen=${#text}
    local pad=$((TUI_W - tlen))
    [[ $pad -lt 0 ]] && pad=0
    printf "${FG_DBLUE}│${RESET}${prefix}%s%${pad}s${RESET}${FG_DBLUE}│${RESET}" "$text" ""
}

# Blue band row (solid blue background)
tui_band_row() {
    printf "${FG_DBLUE}│${RESET}${BG_BLUE}"
    local j; for ((j=0; j<TUI_W; j++)); do printf " "; done
    printf "${RESET}${FG_DBLUE}│${RESET}"
}

# Blue band with centered title (bold white on blue)
tui_band_title() {
    local title="$1"
    local tlen=${#title}
    local lp=$(( (TUI_W - tlen) / 2 ))
    local rp=$((TUI_W - tlen - lp))
    printf "${FG_DBLUE}│${RESET}${BG_BLUE}${FG_WHITE}${BOLD}%${lp}s%s%${rp}s${RESET}${FG_DBLUE}│${RESET}" "" "$title" ""
}

# Blue band with centered subtitle (cyan on blue)
tui_band_sub() {
    local text="$1"
    local tlen=${#text}
    local lp=$(( (TUI_W - tlen) / 2 ))
    local rp=$((TUI_W - tlen - lp))
    printf "${FG_DBLUE}│${RESET}${BG_BLUE}${FG_CYAN}%${lp}s%s%${rp}s${RESET}${FG_DBLUE}│${RESET}" "" "$text" ""
}

# Selected menu item (highlighted, ▸ replaces icon)
# $1=text  $2=icon (optional)
tui_item_on() {
    local text="$1" icon="${2:-}"
    local line="  ▸ ${text}"
    local pad=$((TUI_W - ${#line}))
    [[ $pad -lt 0 ]] && pad=0
    printf "${FG_DBLUE}│${RESET}${BG_SELECT}${FG_WHITE}${BOLD}%s%${pad}s${RESET}${FG_DBLUE}│${RESET}" "$line" ""
}

# Unselected menu item
# $1=text  $2=icon (optional)
tui_item_off() {
    local text="$1" icon="${2:-}"
    local line
    if [[ -n "$icon" ]]; then
        line="  ${icon} ${text}"
    else
        line="    ${text}"
    fi
    local pad=$((TUI_W - ${#line}))
    [[ $pad -lt 0 ]] && pad=0
    printf "${FG_DBLUE}│${RESET}${FG_CYAN}%s%${pad}s${RESET}${FG_DBLUE}│${RESET}" "$line" ""
}
