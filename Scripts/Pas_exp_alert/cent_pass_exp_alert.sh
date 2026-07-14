#!/bin/bash

# ========================================================================
# Centralized Password Expiry Orchestrator (Dual Inventory Engine Version)
# Execute this script ONLY on the Central Management / Hub Server
# ========================================================================

# Global Configuration
ADMIN_EMAILS="duraikavikumar@aliceblueindia.com"
HUB_LOG="/var/log/central_password_expiry.log"
TODAY=$(date +%s)

# ========================================================================
# INVENTORY METHOD A: Hardcoded Embedded Array
# (Uncomment this block and comment out Method B below if using this mode)
# ========================================================================
# PROD_FLEET=(
#     "c3797@192.168.1.10"
#     "sysadmin@192.168.1.11"
#     "ubuntu@192.168.1.12"
#     "itadmin@192.168.1.13"
# )
# TOTAL_NODES=${#PROD_FLEET[@]}

# ========================================================================
# INVENTORY METHOD B: External Host File (ACTIVE DEFAULT)
# (Comment out this block and uncomment Method A if switching modes)
# ========================================================================
INVENTORY_FILE="/home/apocalypto/scripts/host.txt"

if [ ! -f "$INVENTORY_FILE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Configured inventory file missing at: $INVENTORY_FILE" >> "$HUB_LOG"
    exit 1
fi
# Map the lines of the text file directly into the iterable memory array
IFS=$'\n' read -d '' -r -a PROD_FLEET < "$INVENTORY_FILE"
TOTAL_NODES=${#PROD_FLEET[@]}

# Logging Engine
log_hub() {
    local LEVEL="$1"
    local MSG="$2"
    local TIMESTAMP
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$TIMESTAMP] [$LEVEL] $MSG" >> "$HUB_LOG"
    logger -t central-password-alert "[$LEVEL] $MSG"
}

log_hub "INFO" "Initiating centralized orchestration sequence across $TOTAL_NODES variant credential nodes."

# Validate local mail subsystem dependency
if ! command -v mail &> /dev/null; then
    log_hub "ERROR" "Local 'mail' utility missing on Central Hub. Aborting orchestration."
    exit 1
fi

# Global Fleet Aggregators
TOTAL_CHECKED_USERS=0
TOTAL_FLAGGED_ALERTS=0
TOTAL_COMPLIANT_USERS=0
FLEET_DASHBOARD_HTML=""

HIGHEST_SEVERITY="OK"
DIGEST_EMOJI="🟢"
DIGEST_COLOR="#28a745"
DIGEST_BANNER_TEXT="🟢 USER PASSWORD CHECK COMPLETED: NO ACTION REQUIRED"

# ========================================================================
# Fleet Scanning Phase
# ========================================================================
for NODE_PROFILE in "${PROD_FLEET[@]}"; do
    # Skip clean comments or accidental white space lines in file arrays
    [[ -z "$NODE_PROFILE" || "$NODE_PROFILE" =~ ^# ]] && continue 

    # Dynamically extract username and target host targets
    SSH_USER=$(echo "$NODE_PROFILE" | cut -d'@' -f1)
    TARGET_NODE=$(echo "$NODE_PROFILE" | cut -d'@' -f2)

    log_hub "INFO" "Establishing secure session context with production node: [$TARGET_NODE] using user account: [$SSH_USER]"
    
    # Remote execution stream collector (Queries server hostname dynamically)
    if ! REMOTE_DATA=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${SSH_USER}@${TARGET_NODE}" "
        # Capture the local system fully-qualified hostname natively
        LOCAL_HOSTNAME=\$(hostname -f 2>/dev/null || hostname)
        
        while read -r USER; do
            MAX_DAYS=\$(sudo chage -l \"\$USER\" 2>/dev/null | grep \"Maximum number of days between password change\" | awk -F: '{print \$2}' | tr -d ' ')
            LAST_CHANGE_STR=\$(sudo chage -l \"\$USER\" 2>/dev/null | grep \"Last password change\" | awk -F: '{print \$2}')
            
            if [ -z \"\$MAX_DAYS\" ] || [ -z \"\$LAST_CHANGE_STR\" ]; then continue; fi
            
            GECOS_FULL_STRING=\$(sudo getent passwd \"\$USER\" | cut -d: -f5)
            USER_FULL_NAME=\$(echo \"\$GECOS_FULL_STRING\" | cut -d, -f1)
            USER_GECOS_OTHER=\$(echo \"\$GECOS_FULL_STRING\" | cut -d, -f5)
            
            USER_EMAIL=\"\"
            if [[ \"\$USER_GECOS_OTHER\" == *\"email=\"* ]]; then
                USER_EMAIL=\$(echo \"\$USER_GECOS_OTHER\" | sed 's/.*email=\([^,]*\).*/\1/' | tr ' ' ',')
            fi
            
            if [ \"\$MAX_DAYS\" -eq -1 ] || [ \"\$MAX_DAYS\" -eq 99999 ]; then
                echo \"\$LOCAL_HOSTNAME|\$USER|\$MAX_DAYS|\$LAST_CHANGE_STR|\$USER_FULL_NAME|\$USER_EMAIL\"
                continue
            fi
            
            echo \"\$LOCAL_HOSTNAME|\$USER|\$MAX_DAYS|\$LAST_CHANGE_STR|\$USER_FULL_NAME|\$USER_EMAIL\"
        done < <(awk -F: '(\$3 == 0 || \$3 >= 1000) && \$1 != \"nobody\" {print \$1}' /etc/passwd)
    " 2>>"$HUB_LOG"); then
        log_hub "ERROR" "Failed to gather security context payload from host node: [$TARGET_NODE] using user account: [$SSH_USER]"
        
        FLEET_DASHBOARD_HTML+="<div style='border: 1px solid #ebccd1; background-color: #f2dede; color: #a94442; padding: 12px; margin-top: 20px; border-radius: 4px; font-weight: bold;'>🚨 CONNECTION FAILURE: Hub network failed to communicate with managed host node [$TARGET_NODE] using credential profile [$SSH_USER]. Please verify SSH key authorization state.</div>"
        continue
    fi

    # Initialize localized per-server accumulation strings
    SERVER_FLAGGED_ROWS=""
    SERVER_COMPLIANT_ROWS=""
    SERVER_FLAGGED_COUNT=0
    SERVER_COMPLIANT_COUNT=0
    DETECTED_HOSTNAME=""

    # ========================================================================
    # Centralized Metrics Processing Engine
    # ========================================================================
    while IFS='|' read -r REMOTE_HOST_NAME USER MAX_DAYS LAST_CHANGE_STR USER_FULL_NAME USER_EMAIL; do
        [ -z "$USER" ] && continue
        ((TOTAL_CHECKED_USERS++))
        
        # Save the hostname returned by the data stream
        [ -z "$DETECTED_HOSTNAME" ] && DETECTED_HOSTNAME="$REMOTE_HOST_NAME"

        if [ -n "$USER_FULL_NAME" ]; then
            DISPLAY_NAME="$USER_FULL_NAME"
        else
            DISPLAY_NAME="System User"
        fi

        if [ "$MAX_DAYS" = "NEVER" ]; then
            ((SERVER_COMPLIANT_COUNT++))
            ((TOTAL_COMPLIANT_USERS++))
            SERVER_COMPLIANT_ROWS+="<tr><td style='padding:8px;border:1px solid #ddd;color:#555;'>$DISPLAY_NAME</td><td style='padding:8px;border:1px solid #ddd;font-family:monospace;color:#555;'>$USER</td><td style='padding:8px;border:1px solid #ddd;color:#28a745;font-weight:bold;'>Policy Exempt (Never Expires)</td><td style='padding:8px;border:1px solid #ddd;'><span style='background-color:#5cb85c;color:white;padding:2px 6px;font-size:11px;font-weight:bold;border-radius:3px;'>EXEMPT</span></td></tr>"
            continue
        fi

        LAST_CHANGE_EPOCH=$(date -d "$LAST_CHANGE_STR" +%s 2>/dev/null)
        if [ -z "$LAST_CHANGE_EPOCH" ]; then continue; fi

        EXPIRY_EPOCH=$((LAST_CHANGE_EPOCH + (MAX_DAYS * 86400)))
        DAYS_LEFT=$(( (EXPIRY_EPOCH - TODAY) / 86400 ))

        TRIGGER_ALERT=false
        if [ "$DAYS_LEFT" -le 7 ]; then
            TRIGGER_ALERT=true
        fi

        if [ "$TRIGGER_ALERT" = true ]; then
            ((SERVER_FLAGGED_COUNT++))
            ((TOTAL_FLAGGED_ALERTS++))
            
            if [ "$DAYS_LEFT" -lt 0 ]; then
                ABS_DAYS=$(( -DAYS_LEFT ))
                SEVERITY="HIGH / URGENT"
                COLOR="#d9534f" 
                EMOJI="🔴"
                STATUS_TEXT="EXPIRED ($ABS_DAYS days ago)"
                USER_REM="Your account access has expired on production environments. Please contact the <strong>IT Support Team</strong> immediately at <a href='mailto:occurrence@aliceblueindia.com'>occurrence@aliceblueindia.com</a> to verify your profile status and restore server access permissions."
                
                HIGHEST_SEVERITY="HIGH"
                DIGEST_EMOJI="🔴"
                DIGEST_COLOR="#d9534f"
                DIGEST_BANNER_TEXT="⚠️ SECURITY ALERT: USER ACCOUNT LOCKOUT DETECTED"
                
            elif [ "$DAYS_LEFT" -eq 0 ]; then
                SEVERITY="HIGH / URGENT"
                COLOR="#d9534f" 
                EMOJI="🔴"
                STATUS_TEXT="EXPIRING TODAY"
                USER_REM="Your account access expires today. Please contact the <strong>IT Support Team</strong> immediately at <a href='mailto:occurrence@aliceblueindia.com'>occurrence@aliceblueindia.com</a> to complete your compliance update and prevent access lockout."
                
                HIGHEST_SEVERITY="HIGH"
                DIGEST_EMOJI="🔴"
                DIGEST_COLOR="#d9534f"
                DIGEST_BANNER_TEXT="⚠️ SECURITY ALERT: USER ACCOUNT LOCKOUT DETECTED"

            elif [ "$DAYS_LEFT" -le 7 ] && [ "$DAYS_LEFT" -ge 1 ]; then
                SEVERITY="WARNING"
                COLOR="#f0ad4e" 
                EMOJI="🟡"
                STATUS_TEXT="Expiring in $DAYS_LEFT day(s)"
                USER_REM="Please note that your password security lifetime limit will expire shortly. Kindly raise a concern with the <strong>IT Team</strong> via <a href='mailto:occurrence@aliceblueindia.com'>occurrence@aliceblueindia.com</a> to securely rotate your access keys."
                
                if [ "$HIGHEST_SEVERITY" != "HIGH" ]; then
                    HIGHEST_SEVERITY="WARNING"
                    DIGEST_EMOJI="🟡"
                    DIGEST_COLOR="#f0ad4e"
                    DIGEST_BANNER_TEXT="⏳ SECURITY NOTICE: UNRESOLVED EXPIRATION WARNINGS PENDING"
                fi
            fi

            SERVER_FLAGGED_ROWS+="<tr><td style='padding:8px;border:1px solid #ddd;'>$DISPLAY_NAME</td><td style='padding:8px;border:1px solid #ddd;font-family:monospace;'>$USER</td><td style='padding:8px;border:1px solid #ddd;color:$COLOR;font-weight:bold;'>$STATUS_TEXT</td><td style='padding:8px;border:1px solid #ddd;'><span style='background-color:$COLOR;color:white;padding:2px 6px;font-size:11px;font-weight:bold;border-radius:3px;'>$SEVERITY</span></td></tr>"

            # Dispatch personalized notification out to User Inbox directly (uses real hostname)
            if [ -n "$USER_EMAIL" ]; then
                DISPLAY_HOST="${DETECTED_HOSTNAME:-$TARGET_NODE}"
                SUBJECT_LINE="[$SEVERITY] Password Policy Alert: '$USER' on $DISPLAY_HOST"
                read -r -d '' USER_BODY <<EOM
<html>
<body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333333;">
    <div style="max-width: 700px; margin: 0 auto;">
        <div style="background-color: $COLOR; color: white; padding: 15px; font-size: 18px; font-weight: bold; border-radius: 4px;">
            $EMOJI ACCESS PROFILE ALERT: $SEVERITY
        </div>
        <p>Dear $DISPLAY_NAME,</p>
        <p>This automated system message is to notify you regarding your login credential state on our corporate environments.</p>
        
        <table style="border-collapse: collapse; width: 100%; margin: 20px 0;">
            <tr style="background-color: #f9f9f9;"><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold; width: 40%;">Server Hostname:</td><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold; color: #0056b3;">${DETECTED_HOSTNAME:-[Unknown]}</td></tr>
            <tr style="background-color: #ffffff;"><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Connection Endpoint IP:</td><td style="padding: 8px; border: 1px solid #ddd; font-family: monospace;">$TARGET_NODE</td></tr>
            <tr style="background-color: #f9f9f9;"><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold; width: 40%;">User Full Name:</td><td style="padding: 8px; border: 1px solid #ddd;">${USER_FULL_NAME:-[Not Configured]}</td></tr>
            <tr style="background-color: #ffffff;"><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">System Account ID:</td><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">$USER</td></tr>
            <tr style="background-color: #f9f9f9;"><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Account Status:</td><td style="padding: 8px; border: 1px solid #ddd; color: $COLOR; font-weight: bold;">$STATUS_TEXT</td></tr>
        </table>

        <div style="background-color: #f9f9f9; padding: 15px; border-left: 4px solid #0056b3; margin: 20px 0;">
            <p style="margin: 0; font-size: 15px;">$USER_REM</p>
        </div>
        
        <hr style="border: 0; border-top: 1px solid #eeeeee; margin-top: 30px; margin-bottom: 20px;">
        
        <!-- Custom Signature Block -->
        <table style="box-sizing: border-box; border-collapse: collapse; max-width: 100%; font-size: 14px; font-family: Arial; color: rgb(65, 65, 65); background-color: rgb(255, 255, 255); width: 100%;">
            <tbody>
                <tr>
                    <td style="border: 1px solid rgb(221, 221, 221); width: 50%;"><img src="https://ci3.googleusercontent.com/mail-sig/AIorK4wGFAUAtrdZEe9R2RlbmbRzH4Jx9FA0sX5D8Y6FLVxFfeuGhfDbLk9XD4VFw7eJLnkYrC2HQTVgYqOF" style="width: 300px;"></td>
                    <td style="border: 1px solid rgb(221, 221, 221); width: 50%; vertical-align: middle; padding-left: 10px;"><span style="font-family: Ubuntu, sans-serif; font-size: 20px; color: #000;"><strong>SSO-TEAM</strong></span><br><span style="font-family: Poppins, sans-serif; font-size: 20px; color: #4a4a4a;">IT-DEPARTMENT</span><br><b style="font-weight: bolder; color: #222; font-size: large;"><a href="https://www.aliceblueonline.com/" target="_blank" style="color: #1155cc;">www.aliceblueonline.com</a></b><br><a href="mailto:occurrence@aliceblueindia.com"><span style="font-size: small;">occurrence@aliceblueindia.com</span></a></td>
                </tr>
            </tbody>
        </table>
    </div>
</body>
</html>
EOM
                echo "$USER_BODY" | mail -a "MIME-Version: 1.0" -a "Content-Type: text/html; charset=UTF-8" -s "$EMOJI $SUBJECT_LINE" "$USER_EMAIL" 2>>"$HUB_LOG"
            fi
        else
            ((SERVER_COMPLIANT_COUNT++))
            ((TOTAL_COMPLIANT_USERS++))
            SERVER_COMPLIANT_ROWS+="<tr><td style='padding:8px;border:1px solid #ddd;color:#555;'>$DISPLAY_NAME</td><td style='padding:8px;border:1px solid #ddd;font-family:monospace;color:#555;'>$USER</td><td style='padding:8px;border:1px solid #ddd;color:#28a745;'>Active ($DAYS_LEFT days left)</td><td style='padding:8px;border:1px solid #ddd;'><span style='background-color:#28a745;color:white;padding:2px 6px;font-size:11px;font-weight:bold;border-radius:3px;'>PASSED</span></td></tr>"
        fi
    done <<< "$REMOTE_DATA"

    # Default fallback to target connection configuration strings if remote context fails to evaluate
    DISPLAY_SERVER_HEADER="${DETECTED_HOSTNAME:-[Hostname Query Failed]}"

    # ========================================================================
    # HTML Component Compiler for the Current Target Server Node
    # ========================================================================
    read -r -d '' SERVER_BLOCK_HTML <<HTML
    <div style="border: 1px solid #ccc; background-color: #ffffff; padding: 20px; margin-top: 25px; border-radius: 6px; box-shadow: 0 2px 4px rgba(0,0,0,0.02);">
        <h2 style="margin-top: 0; color: #333; border-bottom: 2px solid #0056b3; padding-bottom: 8px;">🖥️ Server: <span style="color: #0056b3;">$DISPLAY_SERVER_HEADER</span> <span style="font-size: 13px; font-weight: normal; color: #666; float: right; margin-top: 8px;">IP Endpoint: <span style="font-family: monospace;">$TARGET_NODE</span> | Session: $SSH_USER</span></h2>
HTML
    FLEET_DASHBOARD_HTML+="$SERVER_BLOCK_HTML"

    # Add localized Action Required segment if any exceptions hit
    if [ "$SERVER_FLAGGED_COUNT" -gt 0 ]; then
        read -r -d '' FLAGGED_TABLE_HTML <<HTML
        <h4 style="color: #d9534f; margin-top: 15px; margin-bottom: 8px;">⚠️ Action Required Profiles ($SERVER_FLAGGED_COUNT)</h4>
        <table style="border-collapse: collapse; width: 100%; margin-bottom: 15px; font-size: 13px;">
            <thead>
                <tr style="background-color: #f9f9f9; text-align: left; border-bottom: 2px solid #d9534f;">
                    <th style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Employee Name</th>
                    <th style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Account ID</th>
                    <th style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Metric / Days Left</th>
                    <th style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Severity</th>
                </tr>
            </thead>
            <tbody>
                $SERVER_FLAGGED_ROWS
            </tbody>
        </table>
HTML
        FLEET_DASHBOARD_HTML+="$FLAGGED_TABLE_HTML"
    fi

    # Add localized Compliant/Exempt segment
    if [ "$SERVER_COMPLIANT_COUNT" -gt 0 ]; then
        read -r -d '' COMPLIANT_TABLE_HTML <<HTML
        <h4 style="color: #28a745; margin-top: 15px; margin-bottom: 8px;">🟢 Compliant System Profiles ($SERVER_COMPLIANT_COUNT)</h4>
        <table style="border-collapse: collapse; width: 100%; font-size: 13px;">
            <thead>
                <tr style="background-color: #f9f9f9; text-align: left; border-bottom: 2px solid #28a745;">
                    <th style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Employee Name</th>
                    <th style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Account ID</th>
                    <th style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Policy Timeline</th>
                    <th style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Status</th>
                </tr>
            </thead>
            <tbody>
                $SERVER_COMPLIANT_ROWS
            </tbody>
        </table>
HTML
        FLEET_DASHBOARD_HTML+="$COMPLIANT_TABLE_HTML"
    else
        if [ "$SERVER_FLAGGED_COUNT" -eq 0 ]; then
            FLEET_DASHBOARD_HTML+="<p style='color: #d9534f; font-weight: bold; font-size: 13px;'>⚠️ Verification Failure: No active accounts fetched from host registry context.</p>"
        fi
    fi

    FLEET_DASHBOARD_HTML+="</div>"
done

# ------------------------------------------------------------------------
# POST-SCAN MASTER REPORT COMPILATION & DELIVERY
# ------------------------------------------------------------------------
ADMIN_SUBJECT="⚙️ SYSTEM FLEET DIGEST: [$HIGHEST_SEVERITY] Password Expiry Report Matrix"

read -r -d '' ADMIN_BODY <<EOM
<html>
<body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333333; background-color: #f4f6f9; padding: 20px;">
    <div style="max-width: 800px; margin: 0 auto; width: 100%;">
        
        <div style="background-color: $DIGEST_COLOR; color: white; padding: 15px; font-size: 18px; font-weight: bold; border-radius: 4px; box-shadow: 0 2px 4px rgba(0,0,0,0.1);">
            $DIGEST_BANNER_TEXT
        </div>
        
        <p style="margin-top: 15px;">Dear Team,</p>
        <p>Automated orchestration infrastructure scans have compiled the password lifecycle tracking records for all active local nodes across the management fleet.</p>
        
        <table style="border-collapse: collapse; width: 100%; margin-bottom: 25px; margin-top: 15px; background-color: #ffffff; border-radius: 4px; box-shadow: 0 1px 3px rgba(0,0,0,0.05);">
            <tr style="background-color: #f9f9f9;"><td style="padding: 10px; border: 1px solid #ddd; font-weight: bold; width: 40%;">Managed Network Nodes:</td><td style="padding: 10px; border: 1px solid #ddd; font-weight: bold; color: #0056b3;">$TOTAL_NODES Servers Scanned</td></tr>
            <tr><td style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">Total Monitored Profiles:</td><td style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">$TOTAL_CHECKED_USERS Accounts Total</td></tr>
            <tr style="background-color: #f9f9f9;"><td style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">Total Flagged Profiles:</td><td style="padding: 10px; border: 1px solid #ddd; font-weight: bold; color: #d9534f;">$TOTAL_FLAGGED_ALERTS Exception(s)</td></tr>
            <tr><td style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">Total Compliant Profiles:</td><td style="padding: 10px; border: 1px solid #ddd; font-weight: bold; color: #28a745;">$TOTAL_COMPLIANT_USERS Verified Safe (Exempt Included)</td></tr>
        </table>

        <!-- Consolidated Dynamic Per-Server Container Output Block -->
        $FLEET_DASHBOARD_HTML

        <div style="background-color: #fcf8e3; color: #8a6d3b; padding: 15px; border-left: 4px solid #f0ad4e; margin: 25px 0 0 0; width: 100%; box-sizing: border-box; border-radius: 0 4px 4px 0;">
            <p style="margin: 0; font-size: 14px;"><strong>Operational Reminder:</strong> Flagged credential validation exceptions represent potential security policy gaps or imminent user lockouts. Please ensure all warning and urgent status profiles are actively evaluated and resolved as soon as possible to maintain infrastructure operational continuity.</p>
        </div>
        
        <hr style="border: 0; border-top: 1px solid #dddddd; margin-top: 30px; margin-bottom: 20px;">
        
        <!-- Custom Corporate Signature -->
        <table style="box-sizing: border-box; border-collapse: collapse; max-width: 100%; font-size: 14px; font-family: Arial; color: rgb(65, 65, 65); background-color: rgb(255, 255, 255); width: 100%;">
            <tbody>
                <tr>
                    <td style="border: 1px solid rgb(221, 221, 221); width: 50%; padding: 10px;"><img src="https://ci3.googleusercontent.com/mail-sig/AIorK4wGFAUAtrdZEe9R2RlbmbRzH4Jx9FA0sX5D8Y6FLVxFfeuGhfDbLk9XD4VFw7eJLnkYrC2HQTVgYqOF" style="width: 300px;"></td>
                    <td style="border: 1px solid rgb(221, 221, 221); width: 50%; vertical-align: middle; padding-left: 15px;"><span style="font-family: Ubuntu, sans-serif; font-size: 20px; color: #000;"><strong>SSO-TEAM</strong></span><br><span style="font-family: Poppins, sans-serif; font-size: 20px; color: #4a4a4a;">IT-DEPARTMENT</span><br><b style="font-weight: bolder; color: #222; font-size: large;"><a href="https://www.aliceblueonline.com/" target="_blank" style="color: #1155cc;">www.aliceblueonline.com</a></b><br><a href="mailto:occurrence@aliceblueindia.com"><span style="font-size: small;">occurrence@aliceblueindia.com</span></a></td>
                </tr>
            </tbody>
        </table>
    </div>
</body>
</html>
EOM

if echo "$ADMIN_BODY" | mail -a "MIME-Version: 1.0" -a "Content-Type: text/html; charset=UTF-8" -s "$DIGEST_EMOJI $ADMIN_SUBJECT" "$ADMIN_EMAILS" 2>>"$HUB_LOG"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Consolidated fleet orchestration report successfully dispatched to $ADMIN_EMAILS." >> "$HUB_LOG"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Failed to deliver master dashboard layout email." >> "$HUB_LOG"
fi

log_hub "INFO" "Fleet evaluation runtime execution sequence finalized cleanly."