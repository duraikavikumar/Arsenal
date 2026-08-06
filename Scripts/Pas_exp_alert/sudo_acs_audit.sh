#!/usr/bin/env bash
# ==============================================================================
# Sudo Access & Privilege Escalation Auditor (sudo_acs)
# Fleet-wide Sequential SSH-based Audit Orchestrator
# ==============================================================================

set -o pipefail

# --- DEFAULT CONFIGURATION & PATHS ---
INVENTORY_FILE="hosts_dev_uat.txt"
LOG_DIR="/var/log/sudo_acs"
REPORT_DIR="/var/log/sudo_acs/reports"
TIMESTAMP=$(date +'%Y-%m-%d_%H:%M:%S')
LOG_FILE="${LOG_DIR}/sudo_acs_${TIMESTAMP}.log"
MD_REPORT="${REPORT_DIR}/sudo_access_report_${TIMESTAMP}.md"
EXECUTED_BY=$(whoami)
VERBOSE=0
CLI_PASSED_ARGS=0

# --- ANSI COLOR CODES ---
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- LOGGING & SYSLOG INTEGRATION ---
syslog_event() {
    local priority="$1"
    local msg="$2"
    logger -t "sudo_acs" -p "auth.${priority}" "[sudo_acs] ${msg}" 2>/dev/null || true
}

log_and_print() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
    local clean_msg
    clean_msg=$(echo -e "${message}" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g')
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${clean_msg}" >> "$LOG_FILE"
}

# --- ANSI-SAFE REMOTE COMMAND EXECUTION ---
run_remote_cmd() {
    local target="$1"
    local cmd="$2"
    local err_file
    err_file=$(mktemp)

    if [[ $VERBOSE -eq 1 ]]; then
        log_and_print "${CYN}" "    [TRACE] SSH Exec on ${target}: ${cmd}" >&2
    fi
    local raw_output
    raw_output=$(ssh -n -q -T -o BatchMode=yes -o ConnectTimeout=5 "$target" "$cmd" 2>"$err_file")
    local exit_code=$?

    # FIXED: Allow exit code 1 (normal when grep finds no match)
    if [[ $exit_code -ne 0 && $exit_code -ne 1 ]]; then
        local err_msg
        err_msg=$(cat "$err_file" | tr -d '\r')
        if [[ -n "$err_msg" ]]; then
            log_and_print "${RED}" "    [!] Error on ${target} (Code ${exit_code}): ${err_msg}" >&2
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR [${target}]: ${err_msg}" >> "$LOG_FILE"
        fi
    fi

    rm -f "$err_file"
    echo "$raw_output" | sed -r 's/\x1B\[[0-9;]*[a-zA-Z]//g' | tr -d '\r'
}

# --- CLI ARGUMENT PARSING ---
usage() {
    echo -e "${BOLD}Sudo Access Audit Orchestrator (sudo_acs)${NC}"
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -i, --inventory FILE   Path to host inventory file (Default: hosts_dev_uat.txt)"
    echo "  -v, --verbose          Enable verbose command tracing to terminal and log file"
    echo "  -h, --help             Display this help message and exit"
    echo ""
    echo "Note: Running without options opens the interactive menu."
    exit 0
}

while [[ $# -gt 0 ]]; do
    CLI_PASSED_ARGS=1
    case "$1" in
        -i|--inventory)
            INVENTORY_FILE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}[!] Unknown argument: $1${NC}"
            usage
            ;;
    esac
done

# --- INTERACTIVE OPTIONS MENU ---
show_interactive_menu() {
    while true; do
        clear
        echo -e "${CYN}================================================================================""${NC}"
        echo -e "${CYN}            SUDO ACCESS & PRIVILEGE AUDITOR (sudo_acs) - OPTIONS MENU          ""${NC}"
        echo -e "${CYN}================================================================================""${NC}"
        echo -e "${BLU}[ Current Configuration ]${NC}"
        echo -e "  1) Target Inventory File : ${BOLD}${INVENTORY_FILE}${NC}"
        echo -e "  2) Execution Mode        : ${BOLD}Sequential (One Server at a Time)${NC}"
        echo -e "  3) Verbose Mode          : ${BOLD}$( [[ $VERBOSE -eq 1 ]] && echo -e "${GRN}ENABLED${NC}" || echo -e "${RED}DISABLED${NC}" )${NC}"
        echo -e "  4) Output Log File       : ${LOG_FILE}"
        echo -e "  5) Output Report         : ${MD_REPORT}"
        echo -e "${CYN}--------------------------------------------------------------------------------""${NC}"
        echo -e "${YEL}[ Options ]${NC}"
        echo -e "  [i] Change Inventory File"
        echo -e "  [v] Toggle Verbose Mode"
        echo -e "  [r] Run Audit Now"
        echo -e "  [q] Quit"
        echo -e "${CYN}================================================================================""${NC}"
        read -rp "Select an option [r/i/v/q]: " OPTION

        case "$OPTION" in
            i|I)
                read -rp "Enter new inventory file path: " NEW_INV
                if [[ -n "$NEW_INV" ]]; then
                    INVENTORY_FILE="$NEW_INV"
                fi
                ;;
            v|V)
                if [[ $VERBOSE -eq 0 ]]; then
                    VERBOSE=1
                else
                    VERBOSE=0
                fi
                ;;
            r|R)
                echo -e "\n${GRN}[+] Starting execution...${NC}\n"
                break
                ;;
            q|Q)
                echo -e "\n${YEL}[*] Exiting without running audit.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[!] Invalid option. Press Enter to retry.${NC}"
                read -r
                ;;
        esac
    done
}

if [[ $CLI_PASSED_ARGS -eq 0 ]]; then
    show_interactive_menu
fi

# --- INITIALIZATION ---
mkdir -p "$LOG_DIR" "$REPORT_DIR"
touch "$LOG_FILE"

syslog_event "notice" "Starting sequential fleet privilege audit executed by ${EXECUTED_BY}"

log_and_print "${CYN}" "================================================================================"
log_and_print "${CYN}" "            STARTING FLEET-WIDE SUDO & PRIVILEGE AUDIT (sudo_acs)             "
log_and_print "${CYN}" "================================================================================"

if [[ ! -f "$INVENTORY_FILE" ]]; then
    log_and_print "${RED}" "[!] ERROR: Inventory file '${INVENTORY_FILE}' not found!"
    syslog_event "err" "Audit aborted: Inventory file missing (${INVENTORY_FILE})"
    exit 1
fi

mapfile -t PROD_FLEET < <(grep -Ev '^\s*($|#)' "$INVENTORY_FILE" | awk '!seen[$0]++')
TOTAL_NODES=${#PROD_FLEET[@]}

if [[ $TOTAL_NODES -eq 0 ]]; then
    log_and_print "${RED}" "[!] ERROR: No valid target hosts found in '${INVENTORY_FILE}'."
    exit 1
fi

# --- INITIALIZE MAIN REPORT HEADER ---
cat << EOF > "$MD_REPORT"
================================================================================
                            SUDO ACCESS REPORT
================================================================================
EOF

# --- SEQUENTIAL AUDIT FUNCTION ---
audit_single_host() {
    local RAW_LINE="$1"
    local TARGET_HOST
    local SERVER_NAME

    # Parse user@IP|Server Name or user@IP
    if [[ "$RAW_LINE" == *"|"* ]]; then
        TARGET_HOST=$(echo "$RAW_LINE" | cut -d'|' -f1 | xargs)
        SERVER_NAME=$(echo "$RAW_LINE" | cut -d'|' -f2- | xargs)
    else
        TARGET_HOST=$(echo "$RAW_LINE" | xargs)
        SERVER_NAME="Not Specified"
    fi

    local TARGET_IP="${TARGET_HOST#*@}"

    # Check SSH Connectivity
    if ! ssh -n -q -T -o BatchMode=yes -o ConnectTimeout=5 "$TARGET_HOST" "exit" 2>>"$LOG_FILE"; then
        log_and_print "${RED}" "  [!] SSH Connection Failed for ${TARGET_HOST}"
        syslog_event "warning" "Host unreachable: ${TARGET_HOST}"

        cat << EOF >> "$MD_REPORT"

# **************************************************************************** #
# Server :- ${SERVER_NAME}
- **IP Address:** ${TARGET_IP}
- **Hostname:** UNREACHABLE
[!] Could not establish SSH connection or key-based authentication failed.

================================================================================
EOF
        return 1
    fi

    # Retrieve Remote Hostname
    local DETECTED_HOSTNAME
    DETECTED_HOSTNAME=$(run_remote_cmd "$TARGET_HOST" "hostname 2>/dev/null || echo 'UNKNOWN'")

    # --------------------------------------------------------------------------
    # 1. ACCESS BY ADDING INTO GROUP
    # --------------------------------------------------------------------------
    local ADMIN_GROUPS_RAW
    ADMIN_GROUPS_RAW=$(run_remote_cmd "$TARGET_HOST" "getent group sudo wheel admin root")

    local GROUP_MEMBERSHIP_SECTION=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local gname
        local gmembers
        gname=$(echo "$line" | cut -d: -f1)
        gmembers=$(echo "$line" | cut -d: -f4)

        local clean_members=""
        if [[ -n "$gmembers" ]]; then
            IFS=',' read -ra ADDR <<< "$gmembers"
            for user in "${ADDR[@]}"; do
                if [[ ! "$user" =~ ^(root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody|systemd.*|messagebus|_.*)$ ]]; then
                    clean_members="${clean_members}${user}, "
                fi
            done
            clean_members="${clean_members%, }"
        fi

        if [[ -n "$clean_members" ]]; then
            GROUP_MEMBERSHIP_SECTION="${GROUP_MEMBERSHIP_SECTION}Group '${gname}': ${clean_members}\n"
        else
            GROUP_MEMBERSHIP_SECTION="${GROUP_MEMBERSHIP_SECTION}Group '${gname}': [No regular users assigned]\n"
        fi
    done <<< "$ADMIN_GROUPS_RAW"

    # --------------------------------------------------------------------------
    # 2. ACCESS BY THE FILE
    # --------------------------------------------------------------------------

    # FIXED: Use find to safely handle empty directories or non-existent paths
    # 2a. Command, User, Runas, and Host Aliases
    local SUDO_ALIASES
    SUDO_ALIASES=$(run_remote_cmd "$TARGET_HOST" "sudo find /etc/sudoers /etc/sudoers.d/ -type f -exec grep -h -E '^(User_Alias|Runas_Alias|Host_Alias|Cmnd_Alias)' {} + 2>/dev/null | grep -v '^\s*$'")

    # 2b. Refined User Directives Parsing (Excludes @includedir, %groups, and Defaults)
    local RAW_SUDO_RULES
    RAW_SUDO_RULES=$(run_remote_cmd "$TARGET_HOST" "sudo find /etc/sudoers /etc/sudoers.d/ -type f -exec grep -H -v -E '^(#|\$|Defaults|User_Alias|Runas_Alias|Host_Alias|Cmnd_Alias|@includedir|\s*$)' {} + 2>/dev/null")

    local FORMATTED_RULES=""
    local CURRENT_FILE=""

    while IFS= read -r rule_line; do
        [[ -z "$rule_line" ]] && continue
        local file_path
        local rule_content
        file_path=$(echo "$rule_line" | cut -d: -f1)
        rule_content=$(echo "$rule_line" | cut -d: -f2- | xargs)

        if [[ "$rule_content" =~ ^root\ +ALL ]] || [[ "$rule_content" =~ ^% ]]; then
            continue
        fi

        if [[ "$file_path" != "$CURRENT_FILE" ]]; then
            CURRENT_FILE="$file_path"
            FORMATTED_RULES="${FORMATTED_RULES}\nFile: ${file_path}\n"
        fi

        FORMATTED_RULES="${FORMATTED_RULES}  Rule: ${rule_content}\n"
    done <<< "$RAW_SUDO_RULES"

    log_and_print "${GRN}" "  [+] Details captured for ${TARGET_HOST} (${DETECTED_HOSTNAME}). Connection closed."

    # Append findings
    cat << EOF >> "$MD_REPORT"

# **************************************************************************** #
# Server :- ${SERVER_NAME}
- **IP Address:** ${TARGET_IP}
- **Hostname:** ${DETECTED_HOSTNAME}

--------------------------------------------------------------------------------
# 1. ACCESS GROUP ADDITION
--------------------------------------------------------------------------------

$(echo -e "${GROUP_MEMBERSHIP_SECTION:-"No administrative group memberships found."}")

--------------------------------------------------------------------------------
# 2. ACCESS BY THE FILE
--------------------------------------------------------------------------------

# [A] Command & User Aliases:
$(echo -e "${SUDO_ALIASES:-"No Aliases Defined."}")

# [B] User Sudo Directive Details:
$(echo -e "${FORMATTED_RULES:-"\nNo custom regular user sudo rules defined."}")

# **************************************************************************** #
EOF
}

# --- MAIN ARRAY-BASED ITERATION LOOP ---
NODE_COUNT=0
log_and_print "${CYN}" "[*] Initiating scan sequence across ${TOTAL_NODES} node(s)..."

for RAW_LINE in "${PROD_FLEET[@]}"; do
    ((NODE_COUNT++))
    log_and_print "${BLU}" "[*] [${NODE_COUNT}/${TOTAL_NODES}] Processing Host Entry: ${RAW_LINE}"

    audit_single_host "$RAW_LINE"
done

# Write report footer after all nodes are processed
cat << EOF >> "$MD_REPORT"

================================================================================
                                END OF REPORT
================================================================================
EOF

log_and_print "${CYN}" "--------------------------------------------------------------------------------"
log_and_print "${GRN}" "[+] AUDIT COMPLETE: Finished auditing ${NODE_COUNT}/${TOTAL_NODES} host(s) sequentially."
log_and_print "${GRN}" "[+] Output Report           : ${MD_REPORT}"
log_and_print "${GRN}" "[+] Log Reference           : ${LOG_FILE}"
log_and_print "${CYN}" "================================================================================"

syslog_event "notice" "Fleet privilege audit completed successfully. Processed ${NODE_COUNT} hosts. Report generated at ${MD_REPORT}"