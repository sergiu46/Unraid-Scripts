##########################################################################
# Log Cleanup & Rotate Logic
# Rotate logs for user scripts plugin and clean old logs on specified paths.
# 
# HOW TO USE:
# 1. Create a new "User Script" in Unraid.
# 2. Copy and uncomment the block below and paste it into the script editor.
# 3. Adjust variables if needed.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---

# #!/bin/bash
#
# PURGE_DAYS=7
# TARGET_PATHS="/var/log /dev/shm"
# LOG_MAX_SIZE="100k"
# LOG_ROTATE_KEEP="1"
# LOG_ARCHIVE="true"
#
# # Script config
# DEBUG="false"
# SCRIPT_DIR="/dev/shm/Log_Cleanup"
# SCRIPT_URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/Log_Cleanup.sh"

# # Download and execute logic
# [[ "$DEBUG" == "true" ]] && rm -rf "$SCRIPT_DIR"
# mkdir -p "$SCRIPT_DIR"
# curl -s -fL "$SCRIPT_URL" -o "$SCRIPT_DIR/Log_Cleanup.sh" || \
# { echo "❌ Logic Download Failed"; exit 1; }
# source "$SCRIPT_DIR/Log_Cleanup.sh"

# --- END COPY ---
#########################################################################

#!/bin/bash

# Default fallbacks to prevent errors if variables are not passed
PURGE_DAYS=${PURGE_DAYS:-7}
TARGET_PATHS=${TARGET_PATHS:-"/var/log /dev/shm"}
LOG_MAX_SIZE=${LOG_MAX_SIZE:-"100k"}
LOG_ROTATE_KEEP=${LOG_ROTATE_KEEP:-"1"}
LOG_ARCHIVE=${LOG_ARCHIVE:-"true"}
SCRIPT_DIR=${SCRIPT_DIR:-"/dev/shm/Log_Cleanup"}

# Paths exclusively for logrotate (leaving Unraid OS paths out to avoid conflicts)
ROTATE_PATHS="/tmp/user.scripts/tmpScripts/*/log.txt"

COMPRESS_DIRECTIVE=""
[[ "$LOG_ARCHIVE" == "true" ]] && COMPRESS_DIRECTIVE="compress"

echo "-------------------------------------------------------"
echo "🔄 Rotating User Script Logs (Size limit: $LOG_MAX_SIZE, Archive: $LOG_ARCHIVE)"
echo ""

# Ensure SCRIPT_DIR exists for config files
mkdir -p "$SCRIPT_DIR"

# Safe Logrotate for all user scripts (isolated from Unraid system state)
LR_CONF="$SCRIPT_DIR/userscripts_logrotate.conf"
LR_STATE="$SCRIPT_DIR/userscripts_logrotate.state"

cat << EOF > "$LR_CONF"
$ROTATE_PATHS {
    size $LOG_MAX_SIZE
    rotate $LOG_ROTATE_KEEP
    maxage $PURGE_DAYS
    $COMPRESS_DIRECTIVE
    copytruncate
    missingok
    notifempty
}
EOF

chmod 0644 "$LR_CONF"
logrotate -s "$LR_STATE" "$LR_CONF"

echo "-------------------------------------------------------"
echo "🧹 Log Cleanup (Files older than $PURGE_DAYS days since last write)"
echo ""

for FOLDER in $TARGET_PATHS; do
    if [ -d "$FOLDER" ]; then
        echo "📂 Searching: $FOLDER"
        echo ""
        
        # Using -mtime (Modification Time)
        find "$FOLDER" -type f -mtime +"$PURGE_DAYS" \( -name "*.log" -o -name "*.log.*" -o -name "*.bak" \) -exec bash -c '
            for file do
                # Use %y for last modification time instead of %x (access time)
                ACC=$(stat -c "%y" "$file" | cut -d"." -f1)
                echo "🗑️ Deleting: $file"
                echo "👁️ Last Written: $ACC"
                rm -f "$file"
                echo ""
            done
        ' bash {} +
    else
        echo "⚠️ Folder not found: $FOLDER"
    fi
done

echo "✅ Log Cleanup & Rotation Finished: $(date)"
echo "-------------------------------------------------------"
echo ""
