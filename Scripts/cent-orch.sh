#!/bin/bash
#
# Centralized Orchestration Script for Ad-hoc Commands and Pre-installed Script Execution
# This script is designed to run on a central server and allows operators to select target environments,
# filter hosts, test connectivity, and execute commands or scripts with deep verbose logging.
#

set -uo pipefail

# Terminal Colors
RED='\033[1;31m'
GRN='\033[1;32m'
YLW='\033[1;33m'
BLU='\033[1;34m'
CYN='\033[1;36m'
NC='\033[0m'

# Capture the local operator running the script on the central server
LOCAL_USER="${SUDO_USER:-$USER}"

# Configuration
LOG_DIR_NAME="automation_logs"

# Resolve local directories
LOCAL_DIR=$(dirname "$(readlink -f "$0")")
LOG_DIR="$LOCAL_DIR/$LOG_DIR_NAME"
LOCAL_LOG_FILE=""
CURRENT_ENV=""
HOSTS_FILE=""

# Arrays to manage targets and hostnames dynamically
declare -a ALL_TARGETS=()
declare -a ACTIVE_TARGETS=()
declare -a ONLINE_TARGETS=()
declare -gA TARGET_HOSTNAMES=()

# Helper: Real-time, line-by-line streaming timestamp filter
# Strips carriage returns in-memory to prevent terminal cursor overwrites
add_timestamps() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        local clean_line="${line//$'\r'/}"
        printf "%s - %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$clean_line"
    done
}

# Helper: Appends local log messages with a timestamp
log_local() {
    local message="$1"
    if [ -n "$LOCAL_LOG_FILE" ] && [ -f "$LOCAL_LOG_FILE" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOCAL_LOG_FILE"
    fi
}

# Dynamic Environment Selector (Scans directory for host files)
select_environment() {
    local choice_limit
    local env_choice
    local -a FOUND_HOST_FILES=()

    # Find all files matching hosts_*.txt in the local script directory
    mapfile -t FOUND_HOST_FILES < <(find "$LOCAL_DIR" -maxdepth 1 -type f -name "hosts_*.txt" | sort)

    if [ ${#FOUND_HOST_FILES[@]} -eq 0 ]; then
        echo -e "${RED}Error: No host files matching 'hosts_*.txt' found in $LOCAL_DIR.${NC}"
        echo -e "${RED}Please create at least one host file (e.g. hosts_prod.txt) before running.${NC}"
        exit 1
    fi

    # IF only one host file exists, auto-select it and bypass the menu entirely
    if [ ${#FOUND_HOST_FILES[@]} -eq 1 ]; then
        HOSTS_FILE=$(basename "${FOUND_HOST_FILES[0]}")
        local env_name
        env_name=$(echo "$HOSTS_FILE" | sed 's/^hosts_//' | sed 's/\.txt$//' | tr '_' ' ' | tr '[:lower:]' '[:upper:]')
        CURRENT_ENV="$env_name"
        echo -e "\n${GRN}[+] Auto-detected single host file: $HOSTS_FILE (Environment: $CURRENT_ENV)${NC}"
        log_local "ENVIRONMENT_AUTO_DETECTED | Operator: $LOCAL_USER | Env: $CURRENT_ENV ($HOSTS_FILE)"
        return
    fi

    # Otherwise, present the choice of discovered host files
    echo -e "\n${BLU}--- SELECT TARGET ENVIRONMENT ---${NC}"
    for i in "${!FOUND_HOST_FILES[@]}"; do
        local fname
        fname=$(basename "${FOUND_HOST_FILES[$i]}")
        local env_display
        env_display=$(echo "$fname" | sed 's/^hosts_//' | sed 's/\.txt$//' | tr '_' ' ' | tr '[:lower:]' '[:upper:]')
        echo "  $((i+1))) $env_display ($fname)"
    done
    echo "  $(( ${#FOUND_HOST_FILES[@]} + 1 ))) Exit Orchestrator"
    
    choice_limit=$(( ${#FOUND_HOST_FILES[@]} + 1 ))
    read -r -p "Choose environment [1-$choice_limit]: " env_choice

    if [[ "$env_choice" =~ ^[0-9]+$ ]] && [ "$env_choice" -eq "$choice_limit" ]; then
        log_local "USER ACTION: Exit during env selection."
        echo "Exiting."
        exit 0
    fi

    if [[ "$env_choice" =~ ^[0-9]+$ ]] && [ "$env_choice" -ge 1 ] && [ "$env_choice" -lt "$choice_limit" ]; then
        HOSTS_FILE=$(basename "${FOUND_HOST_FILES[$((env_choice-1))]}")
        local env_name
        env_name=$(echo "$HOSTS_FILE" | sed 's/^hosts_//' | sed 's/\.txt$//' | tr '_' ' ' | tr '[:lower:]' '[:upper:]')
        CURRENT_ENV="$env_name"
        echo -e "${GRN}Target Environment set to: $CURRENT_ENV ($HOSTS_FILE)${NC}"
        log_local "ENVIRONMENT_CHANGED | Operator: $LOCAL_USER | New Env: $CURRENT_ENV ($HOSTS_FILE)"
    else
        echo -e "${RED}Invalid selection. Please try again.${NC}"
        select_environment
        return
    fi
}

# Step 1: Display targets and filter the list
filter_targets() {
    local select_choice
    local run_nums
    local exclude_nums

    # Read raw host lines, stripping out comments and empty lines
    mapfile -t ALL_TARGETS < <(grep -vE '^\s*(#|$)' "$LOCAL_DIR/$HOSTS_FILE")

    if [ ${#ALL_TARGETS[@]} -eq 0 ]; then
        echo -e "${RED}Error: Selected hosts file is empty or contains only comments.${NC}"
        CURRENT_ENV=""
        HOSTS_FILE=""
        return 1
    fi

    echo -e "\nAvailable Targets in $CURRENT_ENV:"
    for i in "${!ALL_TARGETS[@]}"; do
        echo "  $((i+1))) ${ALL_TARGETS[$i]}"
    done

    echo -e "\nTarget Selection Options:"
    echo "  1) Run on ALL servers"
    echo "  2) Run on SELECTED servers"
    echo "  3) Run on all EXCEPT selected servers (Omit some)"
    read -r -p "Select choice [1-3]: " select_choice

    ACTIVE_TARGETS=()

    case $select_choice in
        1)
            ACTIVE_TARGETS=("${ALL_TARGETS[@]}")
            ;;
        2)
            read -r -p "Enter numbers to run on (space-separated, e.g., 1 3): " run_nums
            for num in $run_nums; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#ALL_TARGETS[@]}" ]; then
                    ACTIVE_TARGETS+=("${ALL_TARGETS[$((num-1))]}")
                fi
            done
            ;;
        3)
            read -r -p "Enter numbers to OMIT/EXCLUDE (space-separated, e.g., 2 4): " exclude_nums
            declare -A exclude_map
            for num in $exclude_nums; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#ALL_TARGETS[@]}" ]; then
                    exclude_map[$((num-1))]=1
                fi
            done
            for i in "${!ALL_TARGETS[@]}"; do
                if [[ -z "${exclude_map[$i]:-}" ]]; then
                    ACTIVE_TARGETS+=("${ALL_TARGETS[$i]}")
                fi
            done
            ;;
        *)
            echo -e "${RED}Invalid selection. Defaulting to ALL servers.${NC}"
            ACTIVE_TARGETS=("${ALL_TARGETS[@]}")
            ;;
    esac

    if [ ${#ACTIVE_TARGETS[@]} -eq 0 ]; then
        echo -e "${RED}Error: Active target list is empty. Reselecting...${NC}"
        filter_targets
        return
    fi
}

# Step 2: Test connection and map hostnames (Unfiltered on Failure, Quiet on Success)
test_connections() {
    local stdout_tmp
    local stderr_tmp
    local remote_hostname

    ONLINE_TARGETS=()
    TARGET_HOSTNAMES=() # Reset map

    echo -e "\n${CYN}--- Verifying Connectivity and Fetching Hostnames ---${NC}"
    log_local "CONNECTIVITY_CHECK: Verifying target reachability with SSH Verbose Handshake."

    for target in "${ACTIVE_TARGETS[@]}"; do
        log_local "TEST_CONNECTION: target=$target"
        
        # Buffer streams locally (SC2155 Compliant)
        stdout_tmp=$(mktemp)
        stderr_tmp=$(mktemp)
        remote_hostname=""

        # Connect and save exit code separately to avoid masking (SC2312/SC1014 Compliant)
        ssh -v -o ConnectTimeout=3 -o StrictHostKeyChecking=no "$target" "hostname" </dev/null > "$stdout_tmp" 2> "$stderr_tmp"
        local ssh_exit_code=$?

        if [ "$ssh_exit_code" -eq 0 ]; then
            remote_hostname=$(tr -d '\r\n' < "$stdout_tmp")
            TARGET_HOSTNAMES["$target"]="$remote_hostname"
            ONLINE_TARGETS+=("$target")
            
            # Success: Keep screen clean and log handshake quietly
            echo -e "Testing $target... [${GRN}ONLINE${NC}] Hostname: ${CYN}$remote_hostname${NC}"
            log_local "TEST_SUCCESS: target=$target | hostname=$remote_hostname"
            # Read from file using redirect instead of cat (SC2002 Compliant)
            add_timestamps < "$stderr_tmp" >> "$LOCAL_LOG_FILE"
        else
            # Failure: Dump the full handshake logs to the terminal screen
            echo -e "Testing $target... [${RED}OFFLINE / TIMEOUT - Handshake Diagnostics Logged Below${NC}]"
            add_timestamps < "$stderr_tmp"
            
            log_local "TEST_FAILURE: target=$target | Connection failed."
            add_timestamps < "$stderr_tmp" >> "$LOCAL_LOG_FILE"
        fi

        rm -f "$stdout_tmp" "$stderr_tmp"
    done

    echo -e "\nConnectivity Check Summary:"
    echo -e "  Total Selected: ${#ACTIVE_TARGETS[@]}"
    echo -e "  Online/Ready:   ${GRN}${#ONLINE_TARGETS[@]}${NC}"
    echo -e "  Offline/Skipped: ${RED}$(( ${#ACTIVE_TARGETS[@]} - ${#ONLINE_TARGETS[@]} ))${NC}"

    if [ ${#ONLINE_TARGETS[@]} -eq 0 ]; then
        echo -e "${RED}Error: No online servers available in current selection.${NC}"
    fi
}

# Unified Setup Pipeline
setup_environment_and_targets() {
    select_environment
    filter_targets
    test_connections
}

# Core Execution Engine
execute_remote_task() {
    local task_type="$1" # "command" or "script"
    local execution_payload=""
    local final_command=""
    local csv_req
    local csv_choice
    local stdout_tmp
    local stderr_tmp

    if [ ${#ONLINE_TARGETS[@]} -eq 0 ]; then
        echo -e "${RED}Error: No online servers available in active selection. Please switch environment or re-select targets.${NC}"
        return
    fi

    if [ "$task_type" == "command" ]; then
        echo -ne "\n${YLW}Enter the command to run (e.g., apt-get update -y): ${NC}"
        read -r execution_payload
        if [ "$execution_payload" == "" ]; then echo -e "${RED}Error: Input cannot be empty.${NC}"; return; fi
        
        # Enforce always-on bash execution trace (bash -x)
        final_command="bash -x -c '$execution_payload'"
    fi

    if [ "$task_type" == "script" ]; then
        echo -ne "\n${YLW}Enter the remote script path and args (e.g., /opt/security-hardening/script-1.sh audit): ${NC}"
        read -r execution_payload
        if [ "$execution_payload" == "" ]; then echo -e "${RED}Error: Input cannot be empty.${NC}"; return; fi
        
        # Enforce always-on bash execution trace (bash -x)
        final_command="bash -x $execution_payload"
    fi

    log_local "EXECUTION_START | Operator: $LOCAL_USER | Task Type: $task_type | Target Env: $CURRENT_ENV | Payload: $final_command"

    # Loop through validated online targets
    for target in "${ONLINE_TARGETS[@]}"; do
        local remote_name="${TARGET_HOSTNAMES[$target]}"
        local border="=========================================================="
        local header="OPERATOR: $LOCAL_USER | TARGET: $target ($remote_name) | EXECUTE: sudo $final_command"
        
        log_local "$border"
        log_local "$header"
        log_local "Host Execution Start: $(date --rfc-3339=seconds)"

        # Buffer streams (SC2155 Compliant)
        stdout_tmp=$(mktemp)
        stderr_tmp=$(mktemp)

        # Execute remote command, storing streams into isolated temporary buffers
        ssh -v -o StrictHostKeyChecking=no "$target" "sudo $final_command" </dev/null > "$stdout_tmp" 2> "$stderr_tmp"
        local exit_code=$?

        # Always write standard output and stderr traces to the central master log file (SC2002 Compliant)
        if [ -s "$stdout_tmp" ]; then
            log_local "--- [$target] STANDARD OUTPUT ---"
            add_timestamps < "$stdout_tmp" >> "$LOCAL_LOG_FILE"
        fi
        if [ -s "$stderr_tmp" ]; then
            log_local "--- [$target] DEBUG & ERROR OUTPUT ---"
            add_timestamps < "$stderr_tmp" >> "$LOCAL_LOG_FILE"
        fi

        # Output transaction headers to the terminal screen
        echo -e "\n${CYN}$border${NC}"
        echo -e "${CYN}$header${NC}"
        echo -e "${CYN}$border${NC}"

        if [ "$exit_code" -eq 0 ]; then
            # SUCCESS (Exit Code 0): Print ONLY the standard output (clean)
            if [ -s "$stdout_tmp" ]; then
                add_timestamps < "$stdout_tmp"
            fi
            echo -e "${CYN}$border${NC}"
            echo -e "${GRN}Finished on $target ($remote_name) (Exit Code: $exit_code)${NC}"
            echo -e "${CYN}$border${NC}"

        elif [ "$exit_code" -eq 255 ]; then
            # SSH CONNECTION/LOGIN FAILURE (Exit Code 255): Print standard output AND the entire raw handshake
            if [ -s "$stdout_tmp" ]; then
                echo -e "${CYN}--- STANDARD OUTPUT ---${NC}"
                add_timestamps < "$stdout_tmp"
            fi
            echo -e "${RED}--- SSH CONNECTION / LOGIN DIAGNOSTICS (HANDSHAKE FAILURE) ---${NC}"
            add_timestamps < "$stderr_tmp"
            
            echo -e "${CYN}$border${NC}"
            echo -e "${RED}Finished on $target ($remote_name) (Exit Code: $exit_code - SSH Connection Error)${NC}"
            echo -e "${CYN}$border${NC}"

        else
            # REMOTE COMMAND FAILURE (Exit Code 1-254): Print standard output and ONLY command errors / traces,
            # using an optimized regex to filter out the SSH protocol connection lines from the screen.
            if [ -s "$stdout_tmp" ]; then
                echo -e "${CYN}--- STANDARD OUTPUT ---${NC}"
                add_timestamps < "$stdout_tmp"
            fi
            echo -e "${RED}--- REMOTE COMMAND ERROR & EXECUTION TRACE ---${NC}"
            # Regex removes kex, ssh_packet, debug1/2/3, authentication lines, and channel allocations from screen
            grep -v -i -E "^(debug[1-3]:|transferred:|bytes per second:|authenticated to|kex_|ssh2_|local version|channel 0|requesting |entering interactive|pledge:|client_input|remote: |sending environment|sending command)" < "$stderr_tmp" | add_timestamps
            
            echo -e "${CYN}$border${NC}"
            echo -e "${RED}Finished on $target ($remote_name) (Exit Code: $exit_code)${NC}"
            echo -e "${CYN}$border${NC}"
        fi

        log_local "Host Execution Finish: $(date --rfc-3339=seconds)"
        log_local "Exit Code: $exit_code"
        log_local "$border"

        rm -f "$stdout_tmp" "$stderr_tmp"
    done
}

# --- Initialization ---
# Create shared log directory
if ! mkdir -p "$LOG_DIR"; then
    echo -e "${RED}FATAL ERROR: Could not create local log directory: $LOG_DIR${NC}"
    exit 1
fi
chmod 777 "$LOG_DIR" 2>/dev/null || true

TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOCAL_LOG_FILE="$LOG_DIR/automation_${LOCAL_USER}_$TIMESTAMP.log"
touch "$LOCAL_LOG_FILE"
chmod 644 "$LOCAL_LOG_FILE" 2>/dev/null || true

echo "--- Local Automation Orchestration Master Log Started ---" > "$LOCAL_LOG_FILE"
log_local "Control runner initialized by operator: $LOCAL_USER"

# Force environment and target validation pipeline immediately upon startup
setup_environment_and_targets

# Main Interface Loop
while true; do
    if ! [ -t 0 ]; then
        echo -e "${RED}ERROR: Script requires an interactive terminal. Exiting.${NC}"
        break
    fi
    
    # Display the menu locked into the currently active target environment
    echo -e "\n--- ${CYN}Automation Orchestrator Menu (Operator: $LOCAL_USER)${NC} ---"
    echo -e "${BLU}Active Env: $CURRENT_ENV | Online Targets: ${#ONLINE_TARGETS[@]} / ${#ACTIVE_TARGETS[@]} | Log Level: DEEP_VERBOSE_ALWAYS${NC}"
    echo "  1) Run Ad-hoc Command"
    echo "  2) Run Automated Script (Pre-installed on targets)"
    echo "  3) Change Target Environment / Reselect Targets"
    echo "  4) Exit"
    read -r -p "Enter choice [1-4]: " choice

    case $choice in
        1) execute_remote_task "command" ;;
        2) execute_remote_task "script" ;;
        3) setup_environment_and_targets ;;
        4) log_local "USER ACTION: Exit."; echo "Exiting."; break ;;
        *) echo -e "${YLW}Invalid choice. Try again.${NC}" ;;
    esac
done