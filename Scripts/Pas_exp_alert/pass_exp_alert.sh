#!/bin/bash

# Configuration
ADMIN_EMAILS="duraikavikumar@aliceblueindia.com"
HOSTNAME=$(hostname -f)
HOST_IP=$(hostname -I | awk '{print $1}')
TODAY=$(date +%s)
LOG_FILE="/var/log/password_expiry.log"

# Logging function
log_message() {
    local LEVEL="$1"
    local MSG="$2"
    local TIMESTAMP
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    # 1. Log to dedicated log file
    echo "[$TIMESTAMP] [$LEVEL] $MSG" >> "$LOG_FILE"
    # 2. Log to system systemd-journal / syslog for log aggregation
    logger -t password-expiry-alert "[$LEVEL] $MSG"
}

log_message "INFO" "Starting periodic cron digest execution sequence."

# Check if required utilities exist
for cmd in awk chage grep date mail; do
    if ! command -v "$cmd" &> /dev/null; then
        log_message "ERROR" "Required command dependency '$cmd' is missing. Aborting execution."
        exit 1
    fi
done

# Ensure the log file has secure permissions if newly created
if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
fi

USER_COUNT=0
ALERT_COUNT=0
COMPLIANT_COUNT=0

ADMIN_TABLE_ROWS=""
COMPLIANT_TABLE_ROWS=""

HIGHEST_SEVERITY="OK"
DIGEST_EMOJI="🟢"
DIGEST_COLOR="#28a745" # Default Compliant Green
DIGEST_BANNER_TEXT="🟢 ALL SYSTEMS NOMINAL: CREDENTIAL POLICY COMPLIANT"

# Loop through root (UID 0) and standard users (UID >= 1000) excluding nobody
while read -r USER; do
    ((USER_COUNT++))
    # Extract aging parameters safely
    MAX_DAYS=$(chage -l "$USER" 2>/dev/null | grep "Maximum number of days between password change" | awk -F: '{print $2}' | tr -d ' ')
    LAST_CHANGE_STR=$(chage -l "$USER" 2>/dev/null | grep "Last password change" | awk -F: '{print $2}')
    # Guard clause: Verify we pulled variables successfully
    if [ -z "$MAX_DAYS" ] || [ -z "$LAST_CHANGE_STR" ]; then
        log_message "WARNING" "Failed to parse password aging parameters for user: $USER"
        continue
    fi
    # Skip accounts with password expiration disabled
    if [ "$MAX_DAYS" -eq -1 ] || [ "$MAX_DAYS" -eq 99999 ]; then
        log_message "INFO" "Skipping user '$USER': Password expiration is disabled."
        continue
    fi
    # Convert last change date to epoch
    LAST_CHANGE_EPOCH=$(date -d "$LAST_CHANGE_STR" +%s 2>/dev/null)
    if [ -z "$LAST_CHANGE_EPOCH" ]; then
        log_message "ERROR" "Invalid last change date format for user '$USER': '$LAST_CHANGE_STR'"
        continue
    fi
    # Compute date metrics
    EXPIRY_EPOCH=$((LAST_CHANGE_EPOCH + (MAX_DAYS * 86400)))
    DAYS_LEFT=$(( (EXPIRY_EPOCH - TODAY) / 86400 ))

    # Parse GECOS Metadata
    GECOS_FULL_STRING=$(getent passwd "$USER" | cut -d: -f5)
    # 1. Extract Full Name (1st comma-separated slot)
    USER_FULL_NAME=$(echo "$GECOS_FULL_STRING" | cut -d, -f1)
    # 2. Extract Email (5th comma-separated "other" slot)
    USER_GECOS_OTHER=$(echo "$GECOS_FULL_STRING" | cut -d, -f5)
    USER_EMAIL=""
    if [[ "$USER_GECOS_OTHER" == *"email="* ]]; then
        # Extracts string and converts spaces to commas if multiple emails exist
        USER_EMAIL=$(echo "$USER_GECOS_OTHER" | sed 's/.*email=\([^,]*\).*/\1/' | tr ' ' ',')
    fi
    # Determine personalized greeting name string
    if [ -n "$USER_FULL_NAME" ]; then
        DISPLAY_NAME="$USER_FULL_NAME"
    else
        DISPLAY_NAME="System User"
    fi

    TRIGGER_ALERT=false
    # Evaluate ranges based on updated two-tier policy requirements (7 to 1 and <= 0)
    if [ "$DAYS_LEFT" -le 7 ]; then
        TRIGGER_ALERT=true
    fi

    # Dispatch Engine
    if [ "$TRIGGER_ALERT" = true ]; then
        ((ALERT_COUNT++))
        
        # Define Tiers and Row Allocations
        if [ "$DAYS_LEFT" -lt 0 ]; then
            ABS_DAYS=$(( -DAYS_LEFT ))
            SEVERITY="HIGH / URGENT"
            COLOR="#d9534f" # Red
            EMOJI="🔴"
            STATUS_TEXT="EXPIRED-$ABS_DAYS days ago"
            USER_REM="Your account access has expired. Please contact the <strong>IT Support Team</strong> immediately at <a href='mailto:occurrence@aliceblueindia.com'>occurrence@aliceblueindia.com</a> to verify your profile status and restore server access permissions."
            # Elevate digest status header if any account is high
            HIGHEST_SEVERITY="HIGH"
            DIGEST_EMOJI="🔴"
            DIGEST_COLOR="#d9534f"
            DIGEST_BANNER_TEXT="⚠️ SECURITY ALERT: ACTIVE LIFECYCLE LOCKOUT DETECTED"
            
        elif [ "$DAYS_LEFT" -eq 0 ]; then
            SEVERITY="HIGH / URGENT"
            COLOR="#d9534f" # Red
            EMOJI="🔴"
            STATUS_TEXT="EXPIRING TODAY"
            USER_REM="Your account access expires today. Please contact the <strong>IT Support Team</strong> immediately at <a href='mailto:occurrence@aliceblueindia.com'>occurrence@aliceblueindia.com</a> to complete your compliance update and prevent access lockout."
            
            HIGHEST_SEVERITY="HIGH"
            DIGEST_EMOJI="🔴"
            DIGEST_COLOR="#d9534f"
            DIGEST_BANNER_TEXT="⚠️ SECURITY ALERT: ACTIVE LIFECYCLE LOCKOUT DETECTED"

        elif [ "$DAYS_LEFT" -le 7 ] && [ "$DAYS_LEFT" -ge 1 ]; then
            SEVERITY="WARNING"
            COLOR="#f0ad4e" # Yellow
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

        # Append data row to the Flagged Admin Digest Matrix
        ADMIN_TABLE_ROWS+="<tr>
            <td style='padding: 8px; border: 1px solid #ddd;'>$DISPLAY_NAME</td>
            <td style='padding: 8px; border: 1px solid #ddd; font-family: monospace;'>$USER</td>
            <td style='padding: 8px; border: 1px solid #ddd; color: $COLOR; font-weight: bold;'>$STATUS_TEXT</td>
            <td style='padding: 8px; border: 1px solid #ddd;'><span style='background-color: $COLOR; color: white; padding: 2px 6px; font-size: 11px; font-weight: bold; border-radius: 3px;'>$SEVERITY</span></td>
        </tr>"

        # Dispatch Immediate Custom Personalized Email directly to the affected User
        if [ -n "$USER_EMAIL" ]; then
            SUBJECT_LINE="[$SEVERITY] Password Policy Alert: '$USER' on $HOSTNAME"
            read -r -d '' USER_BODY <<EOM
<html>
<body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333333;">
    <div style="background-color: $COLOR; color: white; padding: 15px; font-size: 18px; font-weight: bold; border-radius: 4px;">
        $EMOJI ACCESS PROFILE ALERT: $SEVERITY
    </div>
    <p>Dear $DISPLAY_NAME,</p>
    <p>This automated system message is to notify you regarding your login credential state on our corporate environments.</p>
    
    <table style="border-collapse: collapse; width: 100%; max-width: 500px; margin: 20px 0;">
        <tr style="background-color: #f9f9f9;"><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold; width: 40%;">Environment Name:</td><td style="padding: 8px; border: 1px solid #ddd;">$HOSTNAME</td></tr>
        <tr><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Host IP Address:</td><td style="padding: 8px; border: 1px solid #ddd;">$HOST_IP</td></tr>
        <tr style="background-color: #f9f9f9;"><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold; width: 40%;">User Full Name:</td><td style="padding: 8px; border: 1px solid #ddd;">${USER_FULL_NAME:-[Not Configured]}</td></tr>
        <tr><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">System Account ID:</td><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">$USER</td></tr>
        <tr style="background-color: #f9f9f9;"><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold; width: 40%;">Account Status:</td><td style="padding: 8px; border: 1px solid #ddd; color: $COLOR; font-weight: bold;">$STATUS_TEXT</td></tr>
    </table>

    <div style="background-color: #f9f9f9; padding: 15px; border-left: 4px solid #0056b3; margin: 20px 0;">
        <p style="margin: 0; font-size: 15px;">$USER_REM</p>
    </div>
    
    <hr style="border: 0; border-top: 1px solid #eeeeee; margin-top: 30px; margin-bottom: 20px;">
    
    <!-- Custom Corporate Signature -->
    <table style="box-sizing: border-box; border-collapse: collapse; caption-side: bottom; border: 1px solid rgb(221, 221, 221); empty-cells: show; max-width: 100%; font-size: 14px; font-family: Arial; color: rgb(65, 65, 65); background-color: rgb(255, 255, 255); width: 557.656px;">
        <tbody>
            <tr>
                <td style="box-sizing: border-box; border: 1px solid rgb(221, 221, 221); min-width: 5px; width: 313.976px;"><img src="https://ci3.googleusercontent.com/mail-sig/AIorK4wGFAUAtrdZEe9R2RlbmbRzH4Jx9FA0sX5D8Y6FLVxFfeuGhfDbLk9XD4VFw7eJLnkYrC2HQTVgYqOF" style="width: 300px;"></td>
                <td style="box-sizing: border-box; border: 1px solid rgb(221, 221, 221); min-width: 5px; width: 242.569px; vertical-align: middle; padding-left: 10px;"><span style="box-sizing: border-box; font-family: Ubuntu, sans-serif;"><span style="box-sizing: border-box; font-size: 20px; color: rgb(0, 0, 0);"><strong style="box-sizing: border-box; font-weight: 700;">SSO-TEAM</strong></span></span><br><span style="box-sizing: border-box; font-family: Poppins, sans-serif; font-size: 20px; color: rgb(74, 74, 74);">IT-DEPARTMENT</span><br><b style="box-sizing: border-box; font-weight: bolder; color: rgb(34, 34, 34); font-size: large; font-family: Arial;"><span style="color: rgb(0, 0, 0);"><img src="https://ci3.googleusercontent.com/mail-sig/AIorK4xuz4WgqtqL4VaddOC37AYma6ytFElvidGL7Lb1BZkFwIHmuexOmrEWIzM966H4xu17NT4AqZGfCutj" style="box-sizing: border-box; border-style: none; padding: 0px 1px; max-width: calc(100% - 5px); min-width: 5px;">&nbsp;</span></b><span style="color: rgb(0, 0, 0);"><a href="https://www.aliceblueonline.com/" rel="noopener" target="_blank" style="box-sizing: border-box; color: rgb(17, 85, 204); text-decoration: underline; font-family: tahoma, sans-serif;">www.aliceblueonline.com</a></span><br><a href="mailto:occurrence@aliceblueindia.com"><span style="color: rgb(0, 0, 0); font-size: small;">occurrence@aliceblueindia.com</span></a></td>
            </tr>
        </tbody>
    </table>
</body>
</html>
EOM
            echo "$USER_BODY" | mail -a "MIME-Version: 1.0" -a "Content-Type: text/html; charset=UTF-8" -s "$EMOJI $SUBJECT_LINE" "$USER_EMAIL" 2>>"$LOG_FILE"
        fi
    else
        # Account is Passed and Securely within limits -> Add to Compliant list rows
        ((COMPLIANT_COUNT++))
        COMPLIANT_TABLE_ROWS+="<tr>
            <td style='padding: 8px; border: 1px solid #ddd; color: #555;'>$DISPLAY_NAME</td>
            <td style='padding: 8px; border: 1px solid #ddd; font-family: monospace; color: #555;'>$USER</td>
            <td style='padding: 8px; border: 1px solid #ddd; color: #28a745;'>Active ($DAYS_LEFT days left)</td>
            <td style='padding: 8px; border: 1px solid #ddd;'><span style='background-color: #28a745; color: white; padding: 2px 6px; font-size: 11px; font-weight: bold; border-radius: 3px;'>PASSED</span></td>
        </tr>"
    fi

done < <(awk -F: '($3 == 0 || $3 >= 1000) && $1 != "nobody" {print $1}' /etc/passwd)

# ------------------------------------------------------------------------
# POST-LOOP DIGEST CONSTRUCT & DISPATCH
# ------------------------------------------------------------------------
ADMIN_SUBJECT="⚙️ SYSTEM DIGEST: [$HIGHEST_SEVERITY] Password Expiry Report for $HOSTNAME"

# If no flagged users exist, build the empty-state safe notice layout
if [ "$ALERT_COUNT" -eq 0 ]; then
    FLAGGED_SECTION="<p style='color: #28a745; font-weight: bold;'>🎉 Excellent. No local accounts currently match pending lifecycle warnings or expiration deadlines.</p>"
else
    # Build Flagged Account Matrix Table
    read -r -d '' FLAGGED_SECTION <<EOM
    <h3 style="color: #d9534f; margin-top: 25px; margin-bottom: 10px;">⚠️ Action Required Profiles</h3>
    <table style="border-collapse: collapse; width: 100%; max-width: 700px; margin-bottom: 20px;">
        <thead>
            <tr style="background-color: #f2f2f2; text-align: left;">
                <th style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">Employee Name</th>
                <th style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">Account ID</th>
                <th style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">Metric / Days Left</th>
                <th style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">Severity Level</th>
            </tr>
        </thead>
        <tbody>
            $ADMIN_TABLE_ROWS
        </tbody>
    </table>
EOM
fi

# Build Complete Master Digest Body Template
read -r -d '' ADMIN_BODY <<EOM
<html>
<body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333333;">
    <div style="background-color: $DIGEST_COLOR; color: white; padding: 15px; font-size: 18px; font-weight: bold; border-radius: 4px;">
        $DIGEST_BANNER_TEXT
    </div>
    <p>Dear Admin Team,</p>
    <p>Automated infrastructure scans have compiled the periodic credential verification cycle records for this host node.</p>
    
    <table style="border-collapse: collapse; width: 100%; max-width: 600px; margin-bottom: 25px; margin-top: 15px;">
        <tr style="background-color: #f9f9f9;"><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold; width: 35%;">Target Host Name:</td><td style="padding: 8px; border: 1px solid #ddd;">$HOSTNAME</td></tr>
        <tr><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Host IP Address:</td><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">$HOST_IP</td></tr>
        <tr style="background-color: #f9f9f9;"><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold; width: 35%;">Total Flagged Profiles:</td><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold; color: #d9534f;">$ALERT_COUNT</td></tr>
        <tr><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold;">Total Compliant Profiles:</td><td style="padding: 8px; border: 1px solid #ddd; font-weight: bold; color: #28a745;">$COMPLIANT_COUNT</td></tr>
    </table>

    $FLAGGED_SECTION

    <h3 style="color: #28a745; margin-top: 30px; margin-bottom: 10px;">🟢 Compliant System Profiles</h3>
    <table style="border-collapse: collapse; width: 100%; max-width: 700px; margin-bottom: 25px;">
        <thead>
            <tr style="background-color: #f2f2f2; text-align: left;">
                <th style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">Employee Name</th>
                <th style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">Account ID</th>
                <th style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">Policy Timeline</th>
                <th style="padding: 10px; border: 1px solid #ddd; font-weight: bold;">Status</th>
            </tr>
        </thead>
        <tbody>
            $COMPLIANT_TABLE_ROWS
        </tbody>
    </table>

    <div style="background-color: #fcf8e3; color: #8a6d3b; padding: 15px; border-left: 4px solid #f0ad4e; margin: 20px 0; max-width: 700px;">
        <p style="margin: 0; font-size: 14px;"><strong>Operational Reminder:</strong> Flagged credential validation exceptions represent potential security policy gaps or imminent user lockouts. Please ensure all warning and urgent status profiles are actively evaluated and resolved as soon as possible to maintain infrastructure operational continuity.</p>
    </div>
    
    <hr style="border: 0; border-top: 1px solid #eeeeee; margin-top: 30px; margin-bottom: 20px;">
    
    <!-- Custom Corporate Signature -->
    <table style="box-sizing: border-box; border-collapse: collapse; caption-side: bottom; border: 1px solid rgb(221, 221, 221); empty-cells: show; max-width: 100%; font-size: 14px; font-family: Arial; color: rgb(65, 65, 65); background-color: rgb(255, 255, 255); width: 557.656px;">
        <tbody>
            <tr>
                <td style="box-sizing: border-box; border: 1px solid rgb(221, 221, 221); min-width: 5px; width: 313.976px;"><img src="https://ci3.googleusercontent.com/mail-sig/AIorK4wGFAUAtrdZEe9R2RlbmbRzH4Jx9FA0sX5D8Y6FLVxFfeuGhfDbLk9XD4VFw7eJLnkYrC2HQTVgYqOF" style="width: 300px;"></td>
                <td style="box-sizing: border-box; border: 1px solid rgb(221, 221, 221); min-width: 5px; width: 242.569px; vertical-align: middle; padding-left: 10px;"><span style="box-sizing: border-box; font-family: Ubuntu, sans-serif;"><span style="box-sizing: border-box; font-size: 20px; color: rgb(0, 0, 0);"><strong style="box-sizing: border-box; font-weight: 700;">SSO-TEAM</strong></span></span><br><span style="box-sizing: border-box; font-family: Poppins, sans-serif; font-size: 20px; color: rgb(74, 74, 74);">IT-DEPARTMENT</span><br><b style="box-sizing: border-box; font-weight: bolder; color: rgb(34, 34, 34); font-size: large; font-family: Arial;"><span style="color: rgb(0, 0, 0);"><img src="https://ci3.googleusercontent.com/mail-sig/AIorK4xuz4WgqtqL4VaddOC37AYma6ytFElvidGL7Lb1BZkFwIHmuexOmrEWIzM966H4xu17NT4AqZGfCutj" style="box-sizing: border-box; border-style: none; padding: 0px 1px; max-width: calc(100% - 5px); min-width: 5px;">&nbsp;</span></b><span style="color: rgb(0, 0, 0);"><a href="https://www.aliceblueonline.com/" rel="noopener" target="_blank" style="box-sizing: border-box; color: rgb(17, 85, 204); text-decoration: underline; font-family: tahoma, sans-serif;">www.aliceblueonline.com</a></span><br><a href="mailto:occurrence@aliceblueindia.com"><span style="color: rgb(0, 0, 0); font-size: small;">occurrence@aliceblueindia.com</span></a></td>
            </tr>
        </tbody>
    </table>
</body>
</html>
EOM

# Dispatch Master Digest Email
if echo "$ADMIN_BODY" | mail -a "MIME-Version: 1.0" -a "Content-Type: text/html; charset=UTF-8" -s "$DIGEST_EMOJI $ADMIN_SUBJECT" "$ADMIN_EMAILS" 2>>"$LOG_FILE"; then
    log_message "INFO" "Periodic report digest dispatched successfully. Found $ALERT_COUNT issues and $COMPLIANT_COUNT passed users."
else
    log_message "ERROR" "Failed to deliver consolidated administrator report."
fi

log_message "INFO" "Password check sequence completed. Checked: $USER_COUNT users."