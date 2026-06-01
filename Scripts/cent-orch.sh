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

# Environment Selector
select_environment() {
    echo -e "\n${BLU}--- SELECT TARGET ENVIRONMENT ---${NC}"
    echo "1) Dev & UAT"
    echo "2) Production"
    echo "3) Disaster Recovery (DR)"
    echo "4) Exit Orchestrator"
    read -r -p "Choose environment [1-4]: " env_choice

    case $env_choice in
        1) CURRENT_ENV="Dev & UAT"; HOSTS_FILE="hosts_dev_uat.txt" ;;
        2) CURRENT_ENV="Production"; HOSTS_FILE="hosts_prod.txt" ;;
        3) CURRENT_ENV="Disaster Recovery"; HOSTS_FILE="hosts_dr.txt" ;;
        4) log_local "USER ACTION: Exit during env selection."; echo "Exiting."; exit 0 ;;
        *) echo -e "${RED}Invalid selection. Please try again.${NC}"; select_environment; return ;;
    esac

    if [ ! -f "$LOCAL_DIR/$HOSTS_FILE" ]; then
        echo -e "${RED}Error: Host file '$HOSTS_FILE' not found in $LOCAL_DIR.${NC}"
        CURRENT_ENV=""
        HOSTS_FILE=""
        select_environment
        return
    fi
}

# Step 1: Display targets and filter the list
filter_targets() {
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

# Step 2: Test connection and map hostnames (With Always-On Handshake Logging)
test_connections() {
    ONLINE_TARGETS=()
    TARGET_HOSTNAMES=() # Reset map

    echo -e "\n${CYN}--- Verifying Connectivity and Fetching Hostnames ---${NC}"
    log_local "CONNECTIVITY_CHECK: Verifying target reachability with SSH Verbose Handshake."

    for target in "${ACTIVE_TARGETS[@]}"; do
        # We print a newline before testing each host because 'ssh -v' dumps several lines of output.
        echo -e "\nTesting $target... "
        log_local "TEST_CONNECTION: target=$target"
        
        local remote_hostname
        # Connect with '-v' to record all handshake steps in both the local log file and screen.
        # We route stderr through the line-by-line timestamp filter and pipe it to standard error.
        if remote_hostname=$(ssh -v -o ConnectTimeout=3 -o StrictHostKeyChecking=no "$target" "hostname" </dev/null \
            2> >(add_timestamps | tee -a "$LOCAL_LOG_FILE" >&2)); then
            
            remote_hostname=$(echo "$remote_hostname" | tr -d '\r\n')
            TARGET_HOSTNAMES["$target"]="$remote_hostname"
            ONLINE_TARGETS+=("$target")
            echo -e "[${GRN}ONLINE${NC}] Hostname: ${CYN}$remote_hostname${NC}"
            log_local "TEST_SUCCESS: target=$target | hostname=$remote_hostname"
        else
            echo -e "[${RED}OFFLINE / TIMEOUT - Handshake Logged Above${NC}]"
            log_local "TEST_FAILURE: target=$target | Connection failed. Review the log above for full SSH handshake details."
        fi
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
        
        echo -e "\n${CYN}$border${NC}"
        echo -e "${CYN}$header${NC}"
        echo -e "${CYN}$border${NC}"

        log_local "$border"
        log_local "$header"
        log_local "Host Execution Start: $(date --rfc-3339=seconds)"

        # Deep Verbose Execution Pipeline:
        # - stdout/stderr are combined via 2>&1
        # - The unified stream is piped through 'add_timestamps' to stamp every single line
        # - 'tee -a' prints the stamped stream to your terminal and log file simultaneously
        ssh -v -o StrictHostKeyChecking=no "$target" "sudo $final_command" </dev/null 2>&1 \
            | add_timestamps \
            | tee -a "$LOCAL_LOG_FILE"
        local exit_code=${PIPESTATUS[0]}

        log_local "Host Execution Finish: $(date --rfc-3339=seconds)"
        log_local "Exit Code: $exit_code"
        log_local "$border"

        echo -e "${CYN}$border${NC}"
        if [ "$exit_code" -eq 0 ]; then
            echo -e "${GRN}Finished on $target ($remote_name) (Exit Code: $exit_code)${NC}"
        else
            echo -e "${RED}Finished on $target ($remote_name) (Exit Code: $exit_code)${NC}"
        fi
        echo -e "${CYN}$border${NC}"
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