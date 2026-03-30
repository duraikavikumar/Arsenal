#!/bin/bash

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
LOG_FILE="${SCRIPT_DIR}/package-locker_$(date '+%d-%m-%Y_%H:%M:%S').log"
BACKUP_BASE="${SCRIPT_DIR}/apt-locker-backups"
SNAP_DIR="${BACKUP_BASE}/snapshots"
TRANS_DIR="${BACKUP_BASE}/transactions"
PREF_DIR="/etc/apt/preferences.d"

# Timer settings for prompts
PROMPT_TIMEOUT=10
UNATTENDED_PROMPT_LIMIT=3
g_unattended_prompt_count=0

# Colors & Formatting
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CYN='\033[0;36m'
BLU='\033[0;34m'
WHT='\033[1;37m'
NC='\033[0m'
DIM='\033[2m'

# Global variables for parse_ids_from_input result
declare -a PARSED_IDS_RESULT
HAS_INVALID_INPUT_FLAG=false

# --- Core Logging & Auditing Functions ---
init_dirs() {
    run_and_log_cmd mkdir -p "$(dirname "$LOG_FILE")"
    run_and_log_cmd touch "$LOG_FILE"
    log_info "$CYN" "Initializing backup and preference directories..."
    local dirs=("$BACKUP_BASE" "$SNAP_DIR" "$TRANS_DIR" "$PREF_DIR")
    for dir in "${dirs[@]}"; do
        if run_and_log_cmd mkdir -p "$dir"; then
            log_info "$GRN" "Created/Verified: $dir"
        else
            log_info "$RED" "FATAL: Could not create $dir. Check permissions!"
            exit 1
        fi
    done
    log_info "$CYN" "Session Log: ${LOG_FILE}"
    log_info "$CYN" "Backup base set to: ${BACKUP_BASE}"
    log_info "$CYN" "Snapshots will be stored in: ${SNAP_DIR}"
    log_info "$CYN" "Transactions will be stored in: ${TRANS_DIR}"
    log_info "$CYN" "Preference files will be managed in: ${PREF_DIR}"
}

colour_strip() {
    local msg="$1"
    printf '%b\n' "$msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE" 2>/dev/null
}

log_info() {
    local color="$1"
    local message="$2"
    local timestamp; timestamp="[$(date '+%d-%m-%Y %H:%M:%S')]"
    echo -e "${color}${timestamp} ${message}${NC}"
    [[ -n "${LOG_FILE:-}" ]] && colour_strip "${timestamp} ${message}"
}

log_verbatim() {
    local message="$1"
    printf '%b\n' "$message"
    [[ -n "${LOG_FILE:-}" ]] && colour_strip "$message"
}

log_file_only() {
    local message="$1"
    local timestamp; timestamp="[$(date '+%d-%m-%Y %H:%M:%S')]"
    [[ -n "${LOG_FILE:-}" ]] && colour_strip "${timestamp} ${message}"
}

log_ui() {
    local input
    if input=$(cat); then
        echo -en "$input"
        if [[ -n "${LOG_FILE:-}" ]]; then
            echo -en "$input" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE" 2>/dev/null
        fi
    fi
}

run_and_log_cmd() {
    local cmd_str="$*"
    log_file_only "EXECUTING: ${cmd_str}"
    "$@" 2>&1 | while IFS= read -r line; do
        echo "${line}"
        if [[ -n "${LOG_FILE:-}" ]]; then
            local line_ts; line_ts="[$(date '+%d-%m-%Y %H:%M:%S')]"
            colour_strip "${line_ts} ${line}"
        fi
    done
    return "${PIPESTATUS[0]}"
}

capture_stdout_and_log_stderr() {
    local cmd_str="$*"
    log_file_only "CAPTURING STDOUT: ${cmd_str}"
    local temp_output_file; temp_output_file=$(mktemp)
    local exit_status=0
    "$@" > "$temp_output_file" 2> >(
        while IFS= read -r line; do
            echo "${line}" >&2
            if [[ -n "${LOG_FILE:-}" ]]; then
                local line_ts; line_ts="[$(date '+%d-%m-%Y %H:%M:%S')]"
                colour_strip "${line_ts} ${line}"
            fi
        done
    )
    exit_status=$?
    local captured_stdout; captured_stdout=$(cat "$temp_output_file")
    run_and_log_cmd rm "$temp_output_file"
    if [[ -n "$captured_stdout" ]]; then
        log_file_only "--- Captured STDOUT ---"
        log_file_only "$captured_stdout"
        log_file_only "-----------------------"
    else
        log_file_only "Command produced no STDOUT."
    fi
    log_file_only "Command exited with status: $exit_status"
    echo "$captured_stdout"
    return "$exit_status"
}

# --- Prompt with Timer Function ---
prompt_with_timer() {
    local -n result_var=$1
    local prompt_text=$2
    local timeout=$3
    local default=$4
    local user_input=""
    local char
    local start_time; start_time=$(date +%s)
    echo -ne "\033[s\033[K"
    while true; do
        local current_time; current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        local time_left=$((timeout - elapsed_time))
        if (( time_left < 0 )); then user_input=""; break; fi
        echo -ne "\033[u\033[K"
        echo -ne "${YLW}${prompt_text} [${default}] (${time_left}s): ${NC}${user_input}"
        if read -r -s -n 1 -t 0.1 char; then
            if [[ -z "$char" ]]; then break;
            elif [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then user_input="${user_input%?}";
            else user_input+="$char"; fi
        fi
    done
    echo -ne "\033[u\033[K"
    echo
    if [[ -z "$user_input" ]]; then
        log_info "$YLW" "No input provided. Timer expired. Using default answer: '${default}'"
        result_var="$default"
        ((g_unattended_prompt_count++))
        if (( g_unattended_prompt_count >= UNATTENDED_PROMPT_LIMIT )); then
            log_info "$RED" \
"Script has been left unattended for ${UNATTENDED_PROMPT_LIMIT} consecutive prompts. Exiting for safety."
            exit 1
        fi
    else
        log_info "$CYN" "User provided input: '$user_input'"
        result_var="$user_input"
        g_unattended_prompt_count=0
    fi
}

# --- Helper: Parse IDs from User Input ---
is_in_array() {
    local element="$1"
    shift
    local item
    for item; do
        [[ "$item" == "$element" ]] && return 0
    done
    return 1
}

parse_ids_from_input() {
    local user_choice="$1"
    local max_id="$2"
    PARSED_IDS_RESULT=()
    HAS_INVALID_INPUT_FLAG=false
    local temp_ids=()
    log_file_only "Parsing input IDs: '$user_choice' against max_id: $max_id"
    IFS=',' read -ra ADDR <<< "$user_choice"
    for item in "${ADDR[@]}"; do
        item="${item##[[:space:]]}"
        item="${item%%[[:space:]]}"
        [[ -z "$item" ]] && continue
        log_file_only "Processing item: '$item'"
        if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start_id="${BASH_REMATCH[1]}"
            local end_id="${BASH_REMATCH[2]}"
            if (( start_id > 0 && end_id >= start_id && end_id <= max_id )); then
                for (( id=start_id; id<=end_id; id++ )); do 
                    temp_ids+=("$id")
                done
                log_file_only "Expanded range '$item'"
            else
                log_info "$RED" "Invalid range: $item. Must be 1-$max_id and start <= end."
                HAS_INVALID_INPUT_FLAG=true
            fi
        elif [[ "$item" =~ ^[0-9]+$ ]]; then
            if (( item > 0 && item <= max_id )); then
                temp_ids+=("$item")
            else
                log_info "$RED" "Invalid ID: $item. Must be 1-$max_id."
                HAS_INVALID_INPUT_FLAG=true
            fi
        else
            log_info "$RED" "Invalid format: '$item'. Skipping."
            HAS_INVALID_INPUT_FLAG=true
        fi
    done
    if [[ ${#temp_ids[@]} -gt 0 ]]; then
        local sorted_unique_ids
        sorted_unique_ids=$(capture_stdout_and_log_stderr sort -nu <<< "$(printf "%s\n" "${temp_ids[@]}")")
        mapfile -t PARSED_IDS_RESULT <<< "$sorted_unique_ids"
        log_file_only "Parsed IDs: ${PARSED_IDS_RESULT[*]}"
    fi
}

# --- 1. SMART ALPHABET GRID (For Locking) ---
show_smart_alphabet_grid() {
    log_info "$BLU" "--- Displaying Smart Alphabet Grid ---"
    echo -e "${BLU}--- Select Starting Letter ---${NC}" | log_ui
    echo -e "\n${YLW}(Scanning installed packages...)${NC}" | log_ui
    local existing_letters
    existing_letters=$(
        capture_stdout_and_log_stderr "dpkg-query" "-W" "-f=\${Package}\n" \
        | cut -c1 \
        | tr '[:upper:]' '[:lower:]' \
        | sort -u
    )
    local alphabet=("a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l" "m" "n" "o" "p" "q" "r" "s" "t" "u" "v" "w" "x" "y" "z")
    local count=0
    {
        echo "                                  "
        for letter in "${alphabet[@]}"; do
            if echo "$existing_letters" | grep -q "^$letter$"; then
                echo -ne "${GRN}[ ${WHT}${letter^^}${GRN} ]${NC} "
            else
                echo -ne "${DIM}${RED}  -  ${NC} "
            fi
            ((count++))
            if [[ $count -eq 7 ]]; then
                echo -e ""
                count=0
            fi
        done
        echo -e ""
        echo -e "----------------------------"
    } | log_ui
    echo ""
    log_info "$BLU" "--- Smart Alphabet Grid Display Complete ---"
}

# --- 2. SNAPSHOTS & TRANSACTIONS ---
create_global_snapshot() {
    local reason="$1"
    local ts; ts=$(date '+%d-%m-%Y_%H:%M:%S')
    local snap_dir="${SNAP_DIR}/${ts}"
    log_info "$CYN" "Attempting to create global snapshot '${ts}' for reason: ${reason}"
    run_and_log_cmd mkdir -p "$snap_dir"
    local pref_files_exist; pref_files_exist=$(capture_stdout_and_log_stderr find "$PREF_DIR" -maxdepth 1 -type f)
    if [[ -n "$pref_files_exist" ]]; then
        log_info "$CYN" "Backing up existing preference files from '${PREF_DIR}' to '${snap_dir}'."
        run_and_log_cmd cp "${PREF_DIR}/"* "${snap_dir}/"
    else
        log_info "$YLW" "No preference files found in '${PREF_DIR}'. Creating empty marker."
        run_and_log_cmd touch "${snap_dir}/_empty_marker"
    fi
    log_info "$CYN" "Dumping current 'apt-mark showhold' status."
    local apt_mark_output; apt_mark_output=$(capture_stdout_and_log_stderr apt-mark showhold)
    echo "$apt_mark_output" > "${snap_dir}/global_holds.txt"
    log_info "$CYN" "Writing snapshot info file."
    echo "Reason: $reason" > "${snap_dir}/info.txt"
    log_info "$GRN" "Snapshot created: $ts"
}

revert_global_snapshot() {
    local snap_id="$1"
    local target_dir="${SNAP_DIR}/${snap_id}"
    log_info "$CYN" "Attempting to revert to global snapshot '${snap_id}'."
    if [[ ! -d "$target_dir" ]]; then
        log_info "$RED" "ERROR: Snapshot directory '$target_dir' not found!"
        return
    fi
    log_info "$YLW" \
    "WARNING: Rolling back ENTIRE system lock state to '${snap_id}'. This will remove all current pins and holds."
    log_info "$CYN" "Clearing current preferences from '${PREF_DIR}'."
    run_and_log_cmd rm -f "${PREF_DIR}/"*
    log_info "$CYN" "Unholding all currently held packages."
    local current_holds; current_holds=$(capture_stdout_and_log_stderr apt-mark showhold)
    if [[ -n "$current_holds" ]]; then
        run_and_log_cmd apt-mark unhold "$current_holds"
    else
        log_info "$YLW" "No packages currently held by 'apt-mark'."
    fi
    log_info "$CYN" "Restoring preference files from snapshot."
    if [[ ! -f "${target_dir}/_empty_marker" ]]; then
        run_and_log_cmd cp "${target_dir}/"* "${PREF_DIR}/"
        run_and_log_cmd rm -f "${PREF_DIR}/global_holds.txt" "${PREF_DIR}/info.txt"
    else
        log_info "$YLW" "Snapshot indicates no preference files were present. No files restored."
    fi
    log_info "$CYN" "Restoring 'apt-mark hold' status from snapshot."
    if [[ -s "${target_dir}/global_holds.txt" ]]; then
        local holds_to_restore; holds_to_restore=$(cat "${target_dir}/global_holds.txt")
        if [[ -n "$holds_to_restore" ]]; then
            log_info "$CYN" "Packages to re-hold: ${holds_to_restore}"
            run_and_log_cmd xargs -a "${target_dir}/global_holds.txt" apt-mark hold
        else
            log_info "$YLW" "Snapshot 'global_holds.txt' was empty. No packages re-held."
        fi
    else
        log_info "$YLW" "Snapshot 'global_holds.txt' not found or was empty. No packages re-held."
    fi
    log_info "$GRN" "System globally reverted to state: $snap_id"
    log_info "$CYN" "Running 'apt-cache policy' to verify current state (output logged)."
    capture_stdout_and_log_stderr apt-cache policy
}

save_transaction() {
    local pkg="$1"; local action="$2"
    local trans_id; trans_id="$(date '+%d-%m-%Y_%H:%M:%S')_${pkg}"
    local trans_file="${TRANS_DIR}/${trans_id}.state"
    log_info "$CYN" "Saving transaction for package '$pkg' (action: '$action') to '$trans_file'."
    run_and_log_cmd echo "PACKAGE=$pkg" > "$trans_file"
    run_and_log_cmd echo "ACTION=$action" >> "$trans_file"
    log_info "$CYN" "Checking previous 'apt-mark' hold status for '$pkg'."
    if capture_stdout_and_log_stderr apt-mark showhold | grep -q "^${pkg}$"; then
        run_and_log_cmd echo "PREV_HOLD=hold" >> "$trans_file"
    else
        run_and_log_cmd echo "PREV_HOLD=unhold" >> "$trans_file"
    fi
    log_info "$CYN" "Checking previous preference file for '$pkg'."
    local pref_file; pref_file=$(capture_stdout_and_log_stderr find "$PREF_DIR" -type f -name "${pkg}*" | head -n 1)
    if [[ -f "$pref_file" ]]; then
        log_info "$CYN" "Found existing preference file: '$pref_file'. Backing up its content."
        run_and_log_cmd echo "HAS_PREV_PREF=yes" >> "$trans_file"
        run_and_log_cmd echo "PREV_PREF_NAME=$(basename "$pref_file")" >> "$trans_file"
        local pref_content_b64; pref_content_b64=$(capture_stdout_and_log_stderr base64 -w 0 "$pref_file")
        run_and_log_cmd echo "PREV_PREF_CONTENT=$pref_content_b64" >> "$trans_file"
    else 
        log_info "$YLW" "No existing preference file found for '$pkg'."
        run_and_log_cmd echo "HAS_PREV_PREF=no" >> "$trans_file"
    fi
    log_info "$GRN" "Transaction saved: $trans_id"
}

revert_single_transaction() {
    local trans_id="$1"; local trans_file="${TRANS_DIR}/${trans_id}.state"
    log_info "$CYN" "Attempting to revert single transaction: '$trans_id'."
    if [[ ! -f "$trans_file" ]]; then
        log_info "$RED" "ERROR: Transaction file '$trans_file' not found!"
        return
    fi
    log_info "$CYN" "Sourcing transaction details from '$trans_file'."
    # shellcheck disable=SC1090
    source "$trans_file"; 
    log_info "$YLW" "Reverting action for package: $PACKAGE (Transaction ID: $trans_id)."
    log_info "$CYN" "Restoring previous 'apt-mark' hold status: $PREV_HOLD."
    if [[ "$PREV_HOLD" == "hold" ]]; then
        run_and_log_cmd apt-mark hold "$PACKAGE"
    else
        run_and_log_cmd apt-mark unhold "$PACKAGE"
    fi
    log_info "$CYN" "Restoring previous preference file state."
    run_and_log_cmd rm -f "${PREF_DIR}/${PACKAGE}"*
    if [[ "$HAS_PREV_PREF" == "yes" ]]; then 
        log_info "$CYN" "Restoring preference file '${PREV_PREF_NAME}' with backed-up content."
        local decoded_content
        decoded_content=$(capture_stdout_and_log_stderr echo "$PREV_PREF_CONTENT" | base64 -d)
        log_info "$CYN" "Restored content preview for '${PREV_PREF_NAME}':"
        log_verbatim "$decoded_content"
        run_and_log_cmd echo "$decoded_content" > "${PREF_DIR}/${PREV_PREF_NAME}"
    else 
        log_info "$YLW" "Transaction indicates no previous preference file for '$PACKAGE'."
    fi
    log_info "$CYN" "Marking transaction as reverted."
    run_and_log_cmd mv "$trans_file" "${trans_file}.reverted"
    log_info "$GRN" "Transaction '$trans_id' for '$PACKAGE' successfully reverted."
}

# --- 3. EXECUTION (LOCK/UNLOCK SESSIONS) ---
do_lock() {
    local query_pattern
    local last_query_was_all=false
    local last_search_method
    while true; do
        clear
        log_info "$CYN" "--- Entering Package Lock Mode ---"
        echo -e "${CYN}--- Lock a Package ---${NC}"
        echo "1. Search by Name (e.g. 'nginx')"
        echo "2. Filter by Alphabet (Smart Grid)"
        echo "3. List ALL Packages (with paging)"
        echo "4. Lock by Prefix/Wildcard (e.g., php8.2*)"
        echo "5. Back to Main Menu"
        echo ""
        read -r -p "Select Method [1-5]: " smode
        case $smode in
            1) read -r -p "Enter search term: " term
                if [[ -z "$term" ]]; then continue; fi
                query_pattern="$term"
                last_query_was_all=false
                last_search_method="search"
                ;;
            2) show_smart_alphabet_grid
                read -r -p "Enter Letter: " letter
                letter=$(echo "$letter" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
                if [[ -z "$letter" ]]; then continue; fi
                if ! capture_stdout_and_log_stderr "dpkg-query" "-W" "-f=\${Package}\n" | grep -iq "^$letter"; then
                    log_info "$RED" "No pkgs start with '$letter'."
                    sleep 1
                    continue
                fi
                query_pattern="^${letter}"
                last_query_was_all=false
                last_search_method="alphabet"
                ;;
            3) query_pattern=""; last_query_was_all=true; last_search_method="all" ;;
            4) read -r -p "Enter prefix/wildcard (e.g., 'php8.2*', 'libapache2-2.4-mod-*'): " wildcard_pattern
                if [[ -z "$wildcard_pattern" ]]; then
                    log_info "$YLW" "Wildcard pattern not provided. Returning to method selection."
                    continue
                fi
                local filename_slug
                filename_slug=$(capture_stdout_and_log_stderr echo "$wildcard_pattern" | sed 's/[^a-zA-Z0-9_-]//g')
                local matched_pkgs_array=()
                mapfile -t matched_pkgs_array < <(
                    capture_stdout_and_log_stderr "dpkg-query" "-W" "-f=\${Package}\n" \
                    | grep -i "^${wildcard_pattern//\*/.*}$"
                )
                if [[ ${#matched_pkgs_array[@]} -eq 0 ]]; then
                    log_info "$RED" "No installed packages found matching '$wildcard_pattern'."
                    sleep 2
                    continue
                fi
                local packages_string_for_prompt
                packages_string_for_prompt=$(IFS=', '; echo "${matched_pkgs_array[*]}")
                local confirmation_response
                prompt_with_timer confirmation_response \
"Confirm pinning ALL ${#matched_pkgs_array[@]} packages matching '$wildcard_pattern' to current version? \
(e.g., ${packages_string_for_prompt})" "$PROMPT_TIMEOUT" "y"
                if [[ "$confirmation_response" =~ ^[Yy]$ ]]; then
                    local pref_filename="${PREF_DIR}/${filename_slug}_wildcard_pin.pref"
                    local first_pkg_version=""
                    for pkg_name in "${matched_pkgs_array[@]}"; do
                        local ver; ver=$(capture_stdout_and_log_stderr "dpkg-query" "-W" "-f=\${Version}" "$pkg_name")
                        if [[ -n "$ver" ]]; then
                            if [[ -z "$first_pkg_version" ]]; then first_pkg_version="$ver"; fi
                            create_global_snapshot "Pre-Wildcard-Pin $pkg_name"
                            save_transaction "$pkg_name" "LOCK_BY_WILDCARD_PATTERN"
                        fi
                    done
                    log_info "$CYN" "Creating preference file for wildcard pattern: '$pref_filename'."
                    local pref_content="Package: $wildcard_pattern\nPin: version $first_pkg_version\nPin-Priority: 1001"
                    run_and_log_cmd echo -e "$pref_content" > "$pref_filename"
                    log_info "$CYN" "Content of '$pref_filename':"
                    log_verbatim "$pref_content"
                    log_info "$GRN" "WILDCARD PINNING: Pattern '$wildcard_pattern' applied via $pref_filename"
                    echo -e "${GRN}Wildcard pattern pinned. Returning to method selection...${NC}"; sleep 3
                else
                    log_info "$YLW" "Wildcard pinning cancelled for '$wildcard_pattern'. Returning to method selection." ; sleep 2
                fi
                continue
                ;;
            5) log_info "$CYN" "Exiting Package Lock Mode. Returning to Main Menu."; return ;; *) continue ;;
        esac
        local current_idx=0
        while true; do
            log_info "$CYN" "Fetching package list for query pattern: '$query_pattern'."
            mapfile -t ALL_PKGS < <(
                capture_stdout_and_log_stderr "dpkg-query" "-W" "-f=\${Package} \${Version}\n" \
                | grep -i "$query_pattern"
            )
            local total_count=${#ALL_PKGS[@]}
            if [[ $total_count -eq 0 ]]; then
                log_info "$RED" "No packages found for query '$query_pattern'."
                sleep 1
                break
            fi
            local held_packages; held_packages=$(capture_stdout_and_log_stderr "apt-mark" "showhold")
            mapfile -t HELD_PACKAGES_ARRAY <<< "$held_packages"
            local pinned_packages; pinned_packages=$(capture_stdout_and_log_stderr apt-cache policy | awk '/Pinned packages:/ {flag=1; next} flag' | awk '{print $1}')
            mapfile -t PINNED_PACKAGES_ARRAY <<< "$pinned_packages"
            local page_size=40
            clear
            local header_txt; 
            if $last_query_was_all; then header_txt="All Packages";
            elif [[ "$last_search_method" == "alphabet" ]]; then header_txt="Alphabet: '${query_pattern:1}'";
            elif [[ "$last_search_method" == "wildcard" ]]; then header_txt="Prefix/Wildcard: '$query_pattern'";
            else header_txt="Search: '$query_pattern'"; fi
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
                if is_in_array "$p_name" "${HELD_PACKAGES_ARRAY[@]}"; then 
                    status="${RED}LOCKED${NC}"
                elif is_in_array "$p_name" "${PINNED_PACKAGES_ARRAY[@]}"; then
                        status="${RED}LOCKED${NC}"
                fi
                printf "%-6s %-35s %-25s %-10b\n" "[$((i+1))]" "$p_name" "$p_ver" "$status"
            done
            echo "--------------------------------------------------------------------------------"
            echo -e "Showing $((current_idx+1)) to $end_idx of $total_count"
            read -r -p "Type [ID,ID/range] to lock, (n)ext, (p)rev, (b)ack to method selection: " choice
            if [[ "$choice" == "b" ]]; then log_info "$YLW" "Returning to search method selection menu."; break; fi
            if [[ "$choice" == "n" && $end_idx -lt $total_count ]]; then
                log_info "$CYN" "Navigating to next page."
                current_idx=$((current_idx + page_size))
                continue
            fi
            if [[ "$choice" == "p" && $current_idx -gt 0 ]]; then
                log_info "$CYN" "Navigating to previous page."
                current_idx=$((current_idx - page_size))
                continue
            fi
            parse_ids_from_input "$choice" "$total_count"
            if $HAS_INVALID_INPUT_FLAG; then
                log_info "$YLW" "Input contained invalid selections. Prompting user to re-enter."
                sleep 2
                continue
            fi
            if [[ ${#PARSED_IDS_RESULT[@]} -eq 0 ]]; then
                log_info "$YLW" "No valid IDs selected for locking."
                sleep 2
                continue
            fi
            local packages_to_lock_current_batch=(); for id in "${PARSED_IDS_RESULT[@]}"; do
                local pkg_name_from_id; pkg_name_from_id=$(echo "${ALL_PKGS[$((id-1))]}" | awk '{print $1}')
                if echo "$held_packages" | grep -q "^${pkg_name_from_id}$"; then
                    log_info "$YLW" "Package '$pkg_name_from_id' is already locked. Skipping from this batch.";
                else
                    packages_to_lock_current_batch+=("$pkg_name_from_id")
                fi
            done
            if [[ ${#packages_to_lock_current_batch[@]} -eq 0 ]]; then
                log_info "$YLW" "No new packages selected for locking, or all selected were already locked."
                sleep 2
                continue
            fi
            local packages_string_for_prompt
            packages_string_for_prompt=$(IFS=', '; echo "${packages_to_lock_current_batch[*]}")
            local confirmation_response
            prompt_with_timer confirmation_response \
"Confirm locking ${#packages_to_lock_current_batch[@]} package(s): ${packages_string_for_prompt}?" "$PROMPT_TIMEOUT" "y"
            if [[ "$confirmation_response" =~ ^[Yy]$ ]]; then
                log_info "$GRN" "Confirmation received. Proceeding to lock selected packages."
                for pkg_to_lock in "${packages_to_lock_current_batch[@]}"; do
                    create_global_snapshot "Pre-Lock $pkg_to_lock"; save_transaction "$pkg_to_lock" "LOCK"
                    local ver; ver=$(capture_stdout_and_log_stderr "dpkg-query" "-W" "-f=\${Version}" "$pkg_to_lock")
                    log_info "$CYN" "Creating preference file for '$pkg_to_lock'."
                    local pref_content="Package: $pkg_to_lock\nPin: version $ver\nPin-Priority: 1001"
                    run_and_log_cmd echo -e "$pref_content" > "${PREF_DIR}/${pkg_to_lock}.pref"
                    log_info "$CYN" "Content of '${PREF_DIR}/${pkg_to_lock}.pref':"
                    log_verbatim "$pref_content"
                    log_info "$GRN" "LOCKED: $pkg_to_lock @ $ver"
                done
                log_info "$GRN" "Selected package(s) locked. Refreshing list." ; sleep 2
            else
                log_info "$YLW" "Locking cancelled by user for the batch. Refreshing list." ; sleep 2
            fi
        done
    done
}

do_unlock() {
    while true; do
        log_info "$CYN" "--- Entering Package Unlock Mode ---"
        log_info "$YLW" "Scanning for existing locks (Holds & Pins)..."
        local holds; holds=$(capture_stdout_and_log_stderr apt-mark showhold)
        local pins; pins=$(
            capture_stdout_and_log_stderr find "${PREF_DIR}" -type f -printf "%f\n" \
            | sed -E 's/\.(pref|conf|pin)$//'
        )
        local combined_list; combined_list=$(echo -e "$holds\n$pins" | sort -u | sed '/^$/d')
        if [[ -z "$combined_list" ]]; then
            log_info "$RED" "No packages are currently locked. Exiting unlock mode."
            sleep 1.5
            break
        fi
        mapfile -t ALL_LOCKED_PKGS <<< "$combined_list"
        local total_count=${#ALL_LOCKED_PKGS[@]}
        clear
        echo -e "${CYN}--- Unlock a Package(s) ---${NC}"
        printf "${WHT}%-6s %-30s %-15s %-20s${NC}\n" "ID" "PACKAGE NAME" "VERSION" "LOCK TYPE"
        echo "---------------------------------------------------------------------------"
        local i=0
        for pkg in "${ALL_LOCKED_PKGS[@]}"; do
            local ver; ver=$(capture_stdout_and_log_stderr "dpkg-query" "-W" "-f=\${Version}" "$pkg" 2>/dev/null)
            local type_str=""
            local is_held; is_held=$(echo "$holds" | grep -q "^$pkg$"; echo $?)
            local is_pinned=1
            for f in "${PREF_DIR}/${pkg}"*; do
                if [[ -e "$f" ]]; then is_pinned=0; break; fi
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
        read -r -p "Enter [ID,ID/range] to UNLOCK (or 'q' to return to Main Menu): " choice
        if [[ "$choice" == "q" ]]; then
            log_info "$YLW" "Exiting Package Unlock Mode. Returning to Main Menu."
            break
        fi
        parse_ids_from_input "$choice" "$total_count"
        if $HAS_INVALID_INPUT_FLAG; then
            log_info "$YLW" "Input contained invalid selections. Prompting user to re-enter."
            sleep 2
            continue
        fi
        if [[ ${#PARSED_IDS_RESULT[@]} -eq 0 ]]; then
            log_info "$YLW" "No valid IDs selected for unlocking."
            sleep 2
            continue
        fi
        local packages_to_unlock_current_batch=()
        for id in "${PARSED_IDS_RESULT[@]}"; do
            packages_to_unlock_current_batch+=("${ALL_LOCKED_PKGS[$((id-1))]}")
        done
        local packages_string_for_prompt
        packages_string_for_prompt=$(IFS=', '; echo "${packages_to_unlock_current_batch[*]}")
        local confirmation_response
        prompt_with_timer confirmation_response \
"Confirm unlocking ${#packages_to_unlock_current_batch[@]} package(s): ${packages_string_for_prompt}?" "$PROMPT_TIMEOUT" "y"
        if [[ "$confirmation_response" =~ ^[Yy]$ ]]; then
            log_info "$GRN" "Confirmation received. Proceeding to unlock selected packages."
            for pkg_to_unlock in "${packages_to_unlock_current_batch[@]}"; do
                create_global_snapshot "Pre-Unlock $pkg_to_unlock"
                save_transaction "$pkg_to_unlock" "UNLOCK"
                run_and_log_cmd rm -f "${PREF_DIR}/${pkg_to_unlock}"*
                run_and_log_cmd apt-mark unhold "$pkg_to_unlock"
                log_info "$GRN" "UNLOCKED: $pkg_to_unlock"
            done
            log_info "$GRN" "Selected package(s) unlocked. Refreshing list." ; sleep 2
        else
            log_info "$YLW" "Unlocking cancelled by user for the batch. Refreshing list." ; sleep 2
        fi
    done
}

# --- 4. REVERT MENUS (WITH NUMBERED SELECTION) ---
list_and_revert_transaction() {
    clear; log_info "$BLU" "--- Entering Transaction Revert Mode ---"
    echo -e "${BLU}--- Revert a Single Action ---${NC}"
    mapfile -t trans_files < <(run_and_log_cmd ls -1t "${TRANS_DIR}"/*.state 2>/dev/null | head -n 15)
    if [[ ${#trans_files[@]} -eq 0 ]]; then
        log_info "$RED" "No recent transactions found. Exiting revert mode."
        read -r -p "Press Enter to return..." 
        return
    fi
    declare -a trans_ids_map
    echo -e "${WHT} ID   TRANSACTION ID                PACKAGE               ACTION${NC}"
    echo "----------------------------------------------------------------------"
    local i=0
    for f in "${trans_files[@]}"; do
        local id_string; id_string=$(basename "$f" .state)
        local pkg; pkg=$(capture_stdout_and_log_stderr grep "PACKAGE=" "$f" | cut -d= -f2)
        local act; act=$(capture_stdout_and_log_stderr grep "ACTION=" "$f" | cut -d= -f2)
        printf "[%-2d] %-30s %-20s %-10s\n" "$((i+1))" "$id_string" "$pkg" "$act"
        trans_ids_map[i]="$id_string"
        ((i++))
    done
    echo "----------------------------------------------------------------------"
    read -r -p "Enter [ID,ID/range] to revert (or 'q' to cancel): " choice
    if [[ "$choice" == "q" ]]; then
        log_info "$YLW" "Revert cancelled. Returning to main menu."
        read -r -p "Press Enter to return..." 
        return
    fi
    parse_ids_from_input "$choice" "$i"
    if $HAS_INVALID_INPUT_FLAG; then
        log_info "$YLW" "Input contained invalid selections."
        read -r -p "Press Enter to return..." 
        return
    fi
    if [[ ${#PARSED_IDS_RESULT[@]} -eq 0 ]]; then
        log_info "$YLW" "No valid IDs selected for reverting."
        read -r -p "Press Enter to return..." 
        return
    fi
    local transactions_to_revert=()
    for id in "${PARSED_IDS_RESULT[@]}"; do
        transactions_to_revert+=("${trans_ids_map[$((id-1))]}")
    done
    local transactions_string_for_prompt
    transactions_string_for_prompt=$(IFS=', '; echo "${transactions_to_revert[*]}")
    local confirmation_response
    prompt_with_timer confirmation_response \
"Confirm reverting ${#transactions_to_revert[@]} transaction(s): ${transactions_string_for_prompt}?" "$PROMPT_TIMEOUT" "n"
    if [[ "$confirmation_response" =~ ^[Yy]$ ]]; then
        log_info "$GRN" "Confirmation received. Proceeding to revert selected transactions."
        for trans_id_to_revert in "${transactions_to_revert[@]}"; do
            revert_single_transaction "$trans_id_to_revert"
        done
        log_info "$GRN" "Selected transaction(s) reverted. Press Enter to return to menu."
    else
        log_info "$YLW" "Revert cancelled by user for the batch. Press Enter to return to menu."
    fi
}

list_and_revert_snapshot() {
    clear; log_info "$BLU" "--- Entering System Snapshot Revert Mode ---"
    echo -e "${BLU}--- Revert Entire System (Snapshot) ---${NC}"
    mapfile -t snap_dirs < <(run_and_log_cmd ls -1t "$SNAP_DIR" 2>/dev/null | head -n 15)
    if [[ ${#snap_dirs[@]} -eq 0 ]]; then
        log_info "$RED" "No snapshots found. Exiting revert mode."
        read -r -p "Press Enter to return..." 
        return
    fi
    declare -a snap_ids_map
    echo -e "${WHT} ID   SNAPSHOT ID       REASON${NC}"
    echo "--------------------------------------------------"
    local i=0
    for d in "${snap_dirs[@]}"; do
        if [[ -f "${SNAP_DIR}/${d}/info.txt" ]]; then
            local reason; reason=$(capture_stdout_and_log_stderr cat "${SNAP_DIR}/${d}/info.txt" | cut -d: -f2-)
            printf "[%-2d] %-18s %s\n" "$((i+1))" "$d" "$reason"
            snap_ids_map[i]="$d"
            ((i++))
        fi
    done
    echo "--------------------------------------------------"
    read -r -p "Enter [ID,ID/range] to restore (or 'q' to cancel): " choice
    if [[ "$choice" == "q" ]]; then
        log_info "$YLW" "Restore cancelled. Returning to main menu."
        read -r -p "Press Enter to return..." 
        return
    fi
    parse_ids_from_input "$choice" "$i"
    if $HAS_INVALID_INPUT_FLAG; then
        log_info "$YLW" "Input contained invalid selections."
        read -r -p "Press Enter to return..." 
        return
    fi
    if [[ ${#PARSED_IDS_RESULT[@]} -eq 0 ]]; then
        log_info "$YLW" "No valid IDs selected for reverting."
        read -r -p "Press Enter to return..." 
        return
    fi
    local snapshots_to_revert=()
    for id in "${PARSED_IDS_RESULT[@]}"; do
        snapshots_to_revert+=("${snap_ids_map[$((id-1))]}")
    done
    local snapshots_string_for_prompt
    snapshots_string_for_prompt=$(IFS=', '; echo "${snapshots_to_revert[*]}")
    local confirmation_response
    prompt_with_timer confirmation_response \
"Confirm restoring ${#snapshots_to_revert[@]} snapshot(s): ${snapshots_string_for_prompt}? \
This will change your system's lock state!" "$PROMPT_TIMEOUT" "n"
    if [[ "$confirmation_response" =~ ^[Yy]$ ]]; then
        log_info "$GRN" "Confirmation received. Proceeding to restore selected snapshot(s)."
        if [[ ${#snapshots_to_revert[@]} -gt 1 ]]; then
            log_info "$YLW" \
            "Warning: For system snapshots, only the FIRST selected snapshot will be restored, \
            as each revert action overwrites the entire lock state."
            sleep 3
        fi
        revert_global_snapshot "${snapshots_to_revert[0]}"
        log_info "$GRN" "Selected snapshot restored. Press Enter to return to menu."
    else
        log_info "$YLW" "Restore cancelled by user for the batch. Press Enter to return to menu."
    fi
}

# --- 5. MAIN MENU ---
interactive_menu() {
    clear
    log_info "$CYN" "--- Displaying Main Menu ---"
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
        3) list_and_revert_transaction; read -r -p "Press Enter..." ;;
        4) list_and_revert_snapshot; read -r -p "Press Enter..." ;;
        5) log_info "$CYN" "Exiting script."; exit 0 ;;
        *) log_info "$RED" "Invalid option: '$opt'.";;
    esac
}

# --- Main ---
check_root
init_dirs
log_info "$CYN" "--- Script Started ---"
if [[ -n "$1" ]]; then
    log_info "$CYN" "Running in CLI mode with arguments: $*"
    case "$1" in
        lock) do_lock "$2" ;;
        unlock) do_unlock "$2" ;;
        revert-trans) revert_single_transaction "$2" ;;
        revert-snap) revert_global_snapshot "$2" ;;
        *) log_info "$RED" "Invalid CLI usage: '$*'. Usage: $0 [lock|unlock|revert-trans|revert-snap] [arg]"; exit 1 ;;
    esac
else
    log_info "$CYN" "Running in Interactive (Menu) mode."
    while true; do interactive_menu; done
fi
log_info "$CYN" "--- Script Finished ---"