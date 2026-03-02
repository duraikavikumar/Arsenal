#!/bin/bash

# --- Configuration ---
LOG_FILE="/var/log/package-locker.log"
BASE_DIR="/var/backups/apt-locker"
SNAP_DIR="${BASE_DIR}/snapshots"
TRANS_DIR="${BASE_DIR}/transactions"
PREF_DIR="/etc/apt/preferences.d"

# Colors & Formatting
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CYN='\033[0;36m'
BLU='\033[0;34m'
WHT='\033[1;37m'
NC='\033[0m'
DIM='\033[2m'

# --- Core Setup ---
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo -e "${RED}ERROR: Must run as root.${NC}"
        exit 1
    fi
}

init_dirs() {
    mkdir -p "$SNAP_DIR" "$TRANS_DIR" "$PREF_DIR"
    touch "$LOG_FILE"
}

log() {
    local color="$1"
    local msg="$2"
    local ts; ts="[$(date '+%Y-%m-%d %H:%M:%S')]"
    echo -e "${color}${ts} ${msg}${NC}"
    echo "${ts} ${msg}" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

# --- 1. SMART ALPHABET GRID (For Locking) ---
show_smart_alphabet_grid() {
    echo -e "${BLU}--- Select Starting Letter ---${NC}"
    echo -ne "${YLW}(Scanning...)${NC}\r"
    local existing_letters
    existing_letters=$(dpkg-query -W -f='${Package}\n' | cut -c1 | tr '[:upper:]' '[:lower:]' | sort -u)
    local alphabet=("a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "m" "n" "o" "p" "q" "r" "s" "t" "u" "v" "w" "x" "y" "z")
    local count=0
    echo "                                  "
    for letter in "${alphabet[@]}"; do
        if echo "$existing_letters" | grep -q "^$letter$"; then
            echo -ne "${GRN}[ ${WHT}${letter^^}${GRN} ]${NC} "
        else
            echo -ne "${DIM}${RED}  -  ${NC} "
        fi
        ((count++))
        if [[ $count -eq 7 ]]; then
            echo ""
            count=0
        fi
    done
    echo ""
    echo "----------------------------"
}

# --- 2. SNAPSHOTS & TRANSACTIONS ---

create_global_snapshot() {
    local reason="$1"
    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local snap_dir="${SNAP_DIR}/${ts}"
    mkdir -p "$snap_dir"
    if [ "$(ls -A $PREF_DIR)" ]; then
        cp "${PREF_DIR}/"* "${snap_dir}/"
    else
        touch "${snap_dir}/_empty_marker"
    fi
    apt-mark showhold > "${snap_dir}/global_holds.txt"
    echo "Reason: $reason" > "${snap_dir}/info.txt"
    log "$CYN" "Snapshot saved: $ts"
}

revert_global_snapshot() {
    local snap_id="$1"
    local target_dir="${SNAP_DIR}/${snap_id}"
    if [[ ! -d "$target_dir" ]]; then log "$RED" "Snapshot not found."; return; fi
    log "$YLW" "Rolling back system to $snap_id..."
    rm -f "${PREF_DIR}/"* 2>/dev/null
    apt-mark unhold "$(apt-mark showhold)" >/dev/null 2>&1
    if [[ ! -f "${target_dir}/_empty_marker" ]]; then
        cp "${target_dir}/"* "${PREF_DIR}/" 2>/dev/null
        rm -f "${PREF_DIR}/global_holds.txt" "${PREF_DIR}/info.txt"
    fi
    if [[ -s "${target_dir}/global_holds.txt" ]]; then
        xargs -a "${target_dir}/global_holds.txt" apt-mark hold >/dev/null 2>&1
    fi
    log "$GRN" "System restored."
}

save_transaction() {
    local pkg="$1"
    local action="$2"
    local trans_id; trans_id="$(date '+%Y%m%d_%H%M%S')_${pkg}"
    local trans_file="${TRANS_DIR}/${trans_id}.state"
    echo "PACKAGE=$pkg" > "$trans_file"
    echo "ACTION=$action" >> "$trans_file"
    if apt-mark showhold | grep -q "^${pkg}$"; then
        echo "PREV_HOLD=hold" >> "$trans_file"
    else
        echo "PREV_HOLD=unhold" >> "$trans_file"
    fi
    local pref_file; pref_file=$(find "${PREF_DIR}" -maxdepth 1 -name "${pkg}*" 2>/dev/null | head -n 1)
    if [[ -f "$pref_file" ]]; then
        {
            echo "HAS_PREV_PREF=yes"
            echo "PREV_PREF_NAME=$(basename "$pref_file")"
            echo "PREV_PREF_CONTENT=$(base64 -w 0 "$pref_file")"
        } >> "$trans_file"
    else 
        echo "HAS_PREV_PREF=no" >> "$trans_file"
    fi
}

revert_single_transaction() {
    local trans_id="$1"
    local trans_file="${TRANS_DIR}/${trans_id}.state"
    if [[ ! -f "$trans_file" ]]; then
        log "$RED" "Transaction not found."
        return
    fi
    source "$trans_file"
    log "$YLW" "Reverting $PACKAGE..."
    if [[ "$PREV_HOLD" == "hold" ]]; then
        apt-mark hold "$PACKAGE" >/dev/null
    else
        apt-mark unhold "$PACKAGE" >/dev/null
    fi
    rm -f "${PREF_DIR}/${PACKAGE}"*
    if [[ "$HAS_PREV_PREF" == "yes" ]]; then 
        echo "$PREV_PREF_CONTENT" | base64 -d > "${PREF_DIR}/${PREV_PREF_NAME}"
    fi
    mv "$trans_file" "${trans_file}.reverted"
    log "$GRN" "Done."
}

# --- 3. EXECUTION (LOCK/UNLOCK SESSIONS) ---

do_lock() {
    local query_pattern
    local last_query_was_all=false
    while true; do
        clear
        echo -e "${CYN}--- Lock a Package ---${NC}"
        echo "1. Search by Name (e.g. 'nginx')"
        echo "2. Filter by Alphabet (Smart Grid)"
        echo "3. List ALL Packages (with paging)"
        echo "4. Back to Main Menu"
        echo ""
        read -r -p "Select Method [1-4]: " smode
        case $smode in
            1) read -r -p "Enter search term: " term
                if [[ -z "$term" ]]; then
                    continue
                fi
                query_pattern="$term"
                last_query_was_all=false
            ;;
            2) show_smart_alphabet_grid
                read -r -p "Enter Letter: " letter
                letter=$(echo "$letter" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
                if [[ -z "$letter" ]]; then
                    continue
                fi
                if ! dpkg-query -W -f='${Package}\n' | grep -iq "^$letter"; then
                    echo -e "${RED}No pkgs start with '$letter'.${NC}"
                    sleep 1
                    continue
                fi
                query_pattern="^${letter}"
                last_query_was_all=false
            ;;
            3) query_pattern=""; last_query_was_all=true ;;
            4) return ;;
            *) continue ;;
        esac
        local current_idx=0
        while true; do
            echo -e "${YLW}Fetching package list...${NC}"
            mapfile -t ALL_PKGS < <(dpkg-query -W -f='${Package} ${Version}\n' | grep -i "$query_pattern")
            local total_count=${#ALL_PKGS[@]}
            if [[ $total_count -eq 0 ]]; then
                echo -e "${RED}No packages found.${NC}"
                sleep 1
                break
            fi
            local held_packages; held_packages=$(apt-mark showhold)
            local page_size=40
            clear
            local header_txt
            if $last_query_was_all; then
                header_txt="All Packages"
            elif [[ "$query_pattern" == ^* ]]; then
                header_txt="Alphabet: '${query_pattern:1}'"
            else
                header_txt="Search: '$query_pattern'"
            fi
            echo -e "${CYN}--- Results [ $header_txt ] ($total_count found) ---${NC}"
            printf "${WHT}%-6s %-35s %-25s %-10s${NC}\n" "ID" "PACKAGE NAME" "VERSION" "STATUS"
            echo "--------------------------------------------------------------------------------"
            local end_idx=$((current_idx + page_size))
            if [[ $end_idx -gt $total_count ]]; then end_idx=$total_count; fi
            for (( i=current_idx; i<end_idx; i++ )); do
                local line="${ALL_PKGS[$i]}"
                local p_name; p_name=$(echo "$line" | awk '{print $1}')
                local p_ver; p_ver=$(echo "$line" | awk '{print $2}')
                local status="${GRN}Open${NC}"
                if echo "$held_packages" | grep -q "^${p_name}$"; then
                    status="${RED}LOCKED${NC}"
                fi
                printf "%-6s %-35s %-25s %-10b\n" "[$((i+1))]" "$p_name" "$p_ver" "$status"
            done
            echo "--------------------------------------------------------------------------------"
            echo -e "Showing $((current_idx+1)) to $end_idx of $total_count"
            read -r -p "Type [ID] to lock, (n)ext, (p)rev, (b)ack to search menu: " choice
            if [[ "$choice" == "b" ]]; then break; fi
            if [[ "$choice" == "n" && $end_idx -lt $total_count ]]; then
                current_idx=$((current_idx + page_size))
                continue
            fi
            if [[ "$choice" == "p" && $current_idx -gt 0 ]]; then
                current_idx=$((current_idx - page_size))
                continue
            fi
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                local real_idx=$((choice - 1))
                if [[ $real_idx -ge 0 && $real_idx -lt $total_count ]]; then
                    local pkg_to_lock; pkg_to_lock=$(echo "${ALL_PKGS[$real_idx]}" | awk '{print $1}')
                    if echo "$held_packages" | grep -q "^${pkg_to_lock}$"; then
                        echo -e "${YLW}'$pkg_to_lock' is already locked.${NC}"
                        sleep 1.5
                        continue
                    fi
                    create_global_snapshot "Pre-Lock $pkg_to_lock"; save_transaction "$pkg_to_lock" "LOCK"
                    local ver; ver=$(dpkg-query -W -f='${Version}' "$pkg_to_lock")
                    echo "Package: $pkg_to_lock
Pin: version $ver
Pin-Priority: 1001" > "${PREF_DIR}/${pkg_to_lock}.pref"; apt-mark hold "$pkg_to_lock" > /dev/null
                    log "$GRN" "LOCKED: $pkg_to_lock @ $ver"
                    echo -e "${GRN}Locked. Refreshing...${NC}"; sleep 1.5
                else echo -e "${RED}Invalid ID.${NC}"; sleep 1; fi
            fi
        done
    done
}

do_unlock() {
    while true; do
        echo -e "${YLW}Scanning for locks...${NC}"
        local holds; holds=$(apt-mark showhold)
        local pins; pins=$(find "${PREF_DIR}" -type f -printf "%f\n" 2>/dev/null | sed -E 's/\.(pref|conf|pin)$//')
        local combined_list; combined_list=$(echo -e "$holds\n$pins" | sort -u | sed '/^$/d')
        if [[ -z "$combined_list" ]]; then
            echo -e "${RED}No packages are currently locked.${NC}"
            sleep 1.5
            break
        fi
        mapfile -t LOCKED_PKGS <<< "$combined_list"
        local total_count=${#LOCKED_PKGS[@]}
        clear
        echo -e "${CYN}--- Unlock a Package ---${NC}"
        printf "${WHT}%-6s %-30s %-15s %-20s${NC}\n" "ID" "PACKAGE NAME" "VERSION" "LOCK TYPE"
        echo "---------------------------------------------------------------------------"
        local i=0
        for pkg in "${LOCKED_PKGS[@]}"; do
            local ver; ver=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null); local type_str=""
            local is_held; is_held=$(echo "$holds" | grep -q "^$pkg$"; echo $?)
            local is_pinned=1
            for f in "${PREF_DIR}/${pkg}"*; do
                if [[ -e "$f" ]]; then
                    is_pinned=0
                    break
                fi
            done
            if [[ $is_held -eq 0 && $is_pinned -eq 0 ]]; then
                type_str="${GRN}FULL LOCK${NC}"
            elif [[ $is_pinned -eq 0 ]]; then
                type_str="${YLW}PIN ONLY${NC}"
            elif [[ $is_held -eq 0 ]]; then
                type_str="${BLU}HOLD ONLY${NC}"
            fi
            printf "%-6s %-30s %-15s %-20b\n" "[$((i+1))]" "$pkg" "$ver" "$type_str"
            ((i++))
        done
        echo "---------------------------------------------------------------------------"
        read -r -p "Enter ID to UNLOCK (or 'q' to return to Main Menu): " choice

        if [[ "$choice" == "q" || -z "$choice" ]]; then break; fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            local real_idx=$((choice - 1))
            if [[ $real_idx -ge 0 && $real_idx -lt $total_count ]]; then
                local pkg_to_unlock="${LOCKED_PKGS[$real_idx]}"
                create_global_snapshot "Pre-Unlock $pkg_to_unlock"; save_transaction "$pkg_to_unlock" "UNLOCK"
                rm -f "${PREF_DIR}/${pkg_to_unlock}"*; apt-mark unhold "$pkg_to_unlock" > /dev/null
                log "$GRN" "UNLOCKED: $pkg_to_unlock"
                echo -e "${GRN}Unlocked. Refreshing...${NC}"; sleep 1.5
            else echo -e "${RED}Invalid ID.${NC}"; sleep 1; fi
        fi
    done
}

# --- 4. REVERT MENUS (WITH NUMBERED SELECTION) ---

list_and_revert_transaction() {
    clear
    echo -e "${BLU}--- Revert a Single Action (Transaction) ---${NC}"
    mapfile -t trans_files < <(
        find "${TRANS_DIR}" -maxdepth 1 -name '*.state' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n 15 | awk '{print $2}'
    )
    if [[ ${#trans_files[@]} -eq 0 ]]; then echo -e "${RED}No recent transactions found.${NC}"; return; fi
    declare -a trans_ids
    echo -e "${WHT} ID   TRANSACTION ID                PACKAGE               ACTION${NC}"
    echo "----------------------------------------------------------------------"
    local i=0
    for f in "${trans_files[@]}"; do
        local id; id=$(basename "$f" .state)
        local pkg; pkg=$(grep "PACKAGE=" "$f" | cut -d= -f2)
        local act; act=$(grep "ACTION=" "$f" | cut -d= -f2)
        printf "[%-2d] %-30s %-20s %-10s\n" "$((i+1))" "$id" "$pkg" "$act"
        trans_ids[i]="$id"
        ((i++))
    done
    echo "----------------------------------------------------------------------"
    read -r -p "Enter ID number to revert (or 'q' to cancel): " choice
    if [[ "$choice" == "q" || -z "$choice" ]]; then return; fi
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice - 1))
        if [[ -n "${trans_ids[$idx]}" ]]; then
            revert_single_transaction "${trans_ids[$idx]}"
        else
            echo -e "${RED}Invalid ID number.${NC}"
        fi
    else
        echo -e "${RED}Invalid input.${NC}"
    fi
}

list_and_revert_snapshot() {
    clear
    echo -e "${BLU}--- Revert Entire System (Snapshot) ---${NC}"
    mapfile -t snap_dirs < <(
        find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null \
        | sort -nr | head -n 15 | awk '{print $2}'
    )
    if [[ ${#snap_dirs[@]} -eq 0 ]]; then echo -e "${RED}No snapshots found.${NC}"; return; fi
    declare -a snap_ids
    echo -e "${WHT} ID   SNAPSHOT ID       REASON${NC}"
    echo "--------------------------------------------------"
    local i=0
    for d in "${snap_dirs[@]}"; do
        if [[ -f "${SNAP_DIR}/${d}/info.txt" ]]; then
            local reason; reason=$(cat "${SNAP_DIR}/${d}/info.txt" | cut -d: -f2-)
            printf "[%-2d] %-18s %s\n" "$((i+1))" "$d" "$reason"
            snap_ids[i]="$d"
            ((i++))
        fi
    done
    echo "--------------------------------------------------"
    read -r -p "Enter ID number to restore (or 'q' to cancel): " choice
    if [[ "$choice" == "q" || -z "$choice" ]]; then return; fi
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice - 1))
        if [[ -n "${snap_ids[$idx]}" ]]; then
            revert_global_snapshot "${snap_ids[$idx]}"
        else
            echo -e "${RED}Invalid ID number.${NC}"
        fi
    else
        echo -e "${RED}Invalid input.${NC}"
    fi
}

# --- 5. MAIN MENU ---
interactive_menu() {
    clear
    echo -e "${CYN}=== Enterprise Package Locker ===${NC}"
    echo "1. Lock Package(s)"
    echo "2. Unlock Package(s)"
    echo "-----------------------------------"
    echo "3. Revert ONE Change (Transaction)"
    echo "4. Revert SYSTEM (Snapshot)"
    echo "-----------------------------------"
    echo "5. Exit"
    echo ""
    read -r -p "Select option: " opt
    case $opt in
        1) do_lock ;;
        2) do_unlock ;;
        3) 
            list_and_revert_transaction
            read -r -p "Press Enter..."
            ;;
        4) 
            list_and_revert_snapshot
            read -r -p "Press Enter..."
            ;;
        5) exit 0 ;;
        *) ;;
    esac
}

# --- Main ---
check_root
init_dirs
if [[ -n "$1" ]]; then
    case "$1" in
        lock) do_lock "$2" ;;
        unlock) do_unlock "$2" ;;
        revert-trans) revert_single_transaction "$2" ;;
        revert-snap) revert_global_snapshot "$2" ;;
        *) echo "Usage: $0 [lock|unlock|revert-trans|revert-snap] [arg]" ;;
    esac
else
    while true; do interactive_menu; done
fi