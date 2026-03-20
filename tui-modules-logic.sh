#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Modules Logic - Module definitions, state, toggle & POM ops
#  Sourced by: modules
#  Requires: SCRIPT_DIR set by caller, tui-common.sh sourced
#
#  Module definitions are read from modules-conf.txt in the
#  project root (SCRIPT_DIR). See modules-conf.txt.template
#  for the expected format.
# ═══════════════════════════════════════════════════════════════

MODULES_CONF="$SCRIPT_DIR/modules-conf.txt"

if [[ ! -f "$MODULES_CONF" ]]; then
    echo "ERROR: modules-conf.txt not found in $SCRIPT_DIR" >&2
    echo "Copy modules-conf.txt.template from ~/.plaintext-scripts/ and adapt it." >&2
    exit 1
fi

ROOT_POM="$SCRIPT_DIR/pom.xml"
STATE_FILE="$SCRIPT_DIR/.modules-state"

# Webapp POM path: read WEBAPP_MODULE from build-conf.txt if available
if [[ -f "$SCRIPT_DIR/build-conf.txt" ]]; then
    _WEBAPP_MODULE=""
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        value="${value%%#*}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "$key" == "WEBAPP_MODULE" ]]; then
            _WEBAPP_MODULE="$value"
        fi
    done < "$SCRIPT_DIR/build-conf.txt"
    WEBAPP_POM="$SCRIPT_DIR/${_WEBAPP_MODULE}/pom.xml"
else
    # Fallback: try to find from modules-conf.txt WEBAPP_POM setting
    WEBAPP_POM=""
fi

# ── Module definitions (loaded from modules-conf.txt) ────────

ROOT_MODULES=()

# Toggleable modules - parallel arrays for bash 3.2
TOGGLE_NAMES=()
TOGGLE_STATE=()
TOGGLE_GROUP=()    # group name (e.g. "root", "admin", "feature")
TOGGLE_DISPLAY=()  # short display name

add_module() {
    TOGGLE_NAMES+=("$1")
    TOGGLE_STATE+=(1)
    TOGGLE_GROUP+=("$2")
    TOGGLE_DISPLAY+=("$3")
}

# Cross-dependencies between toggleable modules
# Format: "module|dependency" (module needs dependency to build)
DEPS=()

# Modules that cannot be toggled off
LOCKED_TOGGLE=()

# ── Parse modules-conf.txt ────────────────────────────────────
# Format:
#   ROOT_MODULE=<name>
#   TOGGLE=<name>|<group>|<display>
#   DEP=<module>|<dependency>
#   LOCKED=<name>
#   WEBAPP_POM=<relative-path>   (optional override)

while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue

    # Strip inline comments
    line="${line%%#*}"
    # Trim trailing whitespace
    line="${line%"${line##*[![:space:]]}"}"

    local_key="${line%%=*}"
    local_value="${line#*=}"

    case "$local_key" in
        ROOT_MODULE)
            ROOT_MODULES+=("$local_value")
            ;;
        TOGGLE)
            # Format: name|group|display
            IFS='|' read -r t_name t_group t_display <<< "$local_value"
            add_module "$t_name" "$t_group" "$t_display"
            ;;
        DEP)
            DEPS+=("$local_value")
            ;;
        LOCKED)
            LOCKED_TOGGLE+=("$local_value")
            ;;
        WEBAPP_POM)
            WEBAPP_POM="$SCRIPT_DIR/$local_value"
            ;;
    esac
done < "$MODULES_CONF"

TOTAL=${#TOGGLE_NAMES[@]}

# Validate WEBAPP_POM is set
if [[ -z "$WEBAPP_POM" || ! -f "$WEBAPP_POM" ]]; then
    echo "WARNING: WEBAPP_POM not found at '$WEBAPP_POM'. POM manipulation may fail." >&2
fi

# ── Index / Lock helpers ─────────────────────────────────────

# Find index of a module by name
idx_of() {
    local name="$1" i
    for ((i=0; i<TOTAL; i++)); do
        [[ "${TOGGLE_NAMES[$i]}" == "$name" ]] && echo $i && return
    done
    echo -1
}

is_locked() {
    local name="$1" l
    for l in "${LOCKED_TOGGLE[@]}"; do
        [[ "$l" == "$name" ]] && return 0
    done
    return 1
}

# ── Dependency resolution ────────────────────────────────────

# When enabling a module, auto-enable its dependencies
resolve_enable() {
    local name="$1" dep_entry dep mod
    for dep_entry in "${DEPS[@]}"; do
        mod="${dep_entry%%|*}"
        dep="${dep_entry##*|}"
        if [[ "$mod" == "$name" ]]; then
            local di
            di=$(idx_of "$dep")
            if [[ $di -ge 0 && "${TOGGLE_STATE[$di]}" == "0" ]]; then
                TOGGLE_STATE[$di]=1
                resolve_enable "$dep"  # recursive
            fi
        fi
    done
}

# When disabling a module, auto-disable modules that depend on it
resolve_disable() {
    local name="$1" dep_entry dep mod
    for dep_entry in "${DEPS[@]}"; do
        mod="${dep_entry%%|*}"
        dep="${dep_entry##*|}"
        if [[ "$dep" == "$name" ]]; then
            local mi
            mi=$(idx_of "$mod")
            if [[ $mi -ge 0 && "${TOGGLE_STATE[$mi]}" == "1" ]]; then
                TOGGLE_STATE[$mi]=0
                resolve_disable "$mod"  # recursive
            fi
        fi
    done
}

# Toggle with dependency resolution
do_toggle() {
    local idx="$1"
    local name="${TOGGLE_NAMES[$idx]}"

    # Locked modules can't be toggled
    if is_locked "$name"; then
        return
    fi

    if [[ "${TOGGLE_STATE[$idx]}" == "1" ]]; then
        TOGGLE_STATE[$idx]=0
        resolve_disable "$name"
    else
        TOGGLE_STATE[$idx]=1
        resolve_enable "$name"
    fi
}

# ── State persistence ────────────────────────────────────────

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        local i
        for ((i=0; i<TOTAL; i++)); do
            local mod="${TOGGLE_NAMES[$i]}"
            local val
            val=$(grep "^${mod}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
            if [[ "$val" == "0" ]]; then
                TOGGLE_STATE[$i]=0
            fi
        done
    fi
    # Enforce locked modules are always on
    local i
    for ((i=0; i<TOTAL; i++)); do
        if is_locked "${TOGGLE_NAMES[$i]}"; then
            TOGGLE_STATE[$i]=1
        fi
    done
}

save_state() {
    local i
    > "$STATE_FILE"
    for ((i=0; i<TOTAL; i++)); do
        echo "${TOGGLE_NAMES[$i]}=${TOGGLE_STATE[$i]}" >> "$STATE_FILE"
    done
}

has_disabled() {
    local i
    for ((i=0; i<TOTAL; i++)); do
        [[ "${TOGGLE_STATE[$i]}" == "0" ]] && return 0
    done
    return 1
}

count_enabled() {
    local count=0 i
    for ((i=0; i<TOTAL; i++)); do
        [[ "${TOGGLE_STATE[$i]}" == "1" ]] && count=$((count + 1))
    done
    echo $count
}

# ── POM manipulation ─────────────────────────────────────────

apply_changes() {
    # Restore everything first, then disable selected modules
    # Collect disabled module names
    local disabled_mods=""
    local i
    for ((i=0; i<TOTAL; i++)); do
        if [[ "${TOGGLE_STATE[$i]}" == "0" ]]; then
            disabled_mods="${disabled_mods} ${TOGGLE_NAMES[$i]}"
        fi
    done

    # Root pom.xml: restore all then disable
    sed -i.bak 's|<!-- <module>\(.*\)</module> -->|<module>\1</module>|g' "$ROOT_POM"
    rm -f "${ROOT_POM}.bak"
    for mod in $disabled_mods; do
        sed -i.bak "s|<module>${mod}</module>|<!-- <module>${mod}</module> -->|g" "$ROOT_POM"
        rm -f "${ROOT_POM}.bak"
    done

    # Webapp pom.xml: use Python with sys.argv to avoid escaping issues
    if [[ -n "$WEBAPP_POM" && -f "$WEBAPP_POM" ]]; then
        python3 - "$WEBAPP_POM" $disabled_mods <<'PYEOF'
import re, sys

pom_path = sys.argv[1]
disabled = sys.argv[2:]

with open(pom_path, 'r') as f:
    content = f.read()

# First restore any previously disabled
content = re.sub(r'<!-- DISABLED\n(.*?)\n-->', r'\1', content, flags=re.DOTALL)

# Now disable each module
for mod in disabled:
    pattern = (
        r'(        <dependency>\n'
        r'            <groupId>ch\.plaintext</groupId>\n'
        r'            <artifactId>' + re.escape(mod) + r'</artifactId>'
        r'(?:\n            <version>[^<]*</version>)?'
        r'\n        </dependency>)'
    )
    content = re.sub(pattern, r'<!-- DISABLED' + '\n' + r'\1' + '\n' + '-->', content)

with open(pom_path, 'w') as f:
    f.write(content)
PYEOF
    fi
}

restore_all() {
    sed -i.bak 's|<!-- <module>\(.*\)</module> -->|<module>\1</module>|g' "$ROOT_POM"
    rm -f "${ROOT_POM}.bak"

    if [[ -n "$WEBAPP_POM" && -f "$WEBAPP_POM" ]]; then
        python3 - "$WEBAPP_POM" <<'PYEOF'
import re, sys

pom_path = sys.argv[1]
with open(pom_path, 'r') as f:
    content = f.read()
content = re.sub(r'<!-- DISABLED\n(.*?)\n-->', r'\1', content, flags=re.DOTALL)
with open(pom_path, 'w') as f:
    f.write(content)
PYEOF
    fi
    rm -f "$STATE_FILE"
}

save_and_apply() {
    echo -e "${FG_BLUE}${BOLD}Applying module changes...${RESET}"
    if ! has_disabled; then
        restore_all
        echo -e "${FG_GREEN}All modules enabled (full build)${RESET}"
    else
        save_state
        apply_changes
        enabled=$(count_enabled)
        echo -e "${FG_GREEN}${enabled}/${TOTAL} modules enabled${RESET}"
        echo -e "${FG_DIM}Disabled:${RESET}"
        for ((i=0; i<TOTAL; i++)); do
            if [[ "${TOGGLE_STATE[$i]}" == "0" ]]; then
                echo -e "  ${FG_DIM}  ${TOGGLE_NAMES[$i]}${RESET}"
            fi
        done
    fi
}
