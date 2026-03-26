##########################################################################
# NginX Snippets Sync Logic
# 
# HOW TO USE:
# 1. Create a new "User Script" in Unraid.
# 2. Copy and uncomment the block below and paste it into the script editor.
# 3. Adjust variables (PURGE_DAYS, TARGET_PATH) if needed.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---

# #!/bin/bash
#
# PURGE_DAYS=7
# TARGET_PATHS="/var/log /dev/shm"

# # Script config
# DEBUG="false"
# SCRIPT_DIR="/dev/shm/Log_Cleanup"
# SCRIPT_URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/Log_Cleanup.sh"

# # Download and execute logic
# [[ "$DEBUG" == "true" ]] && rm -rf "$SCRIPT_DIR"
# mkdir -p "$SCRIPT_DIR"
# curl -s -fL "$SCRIPT_URL" -o "$SCRIPT_DIR/Log_Cleanup.sh" || { echo "❌ Logic Download Failed"; exit 1; }
# source "$SCRIPT_DIR/Log_Cleanup.sh"

# --- END COPY ---
#########################################################################

#!/bin/bash

# Automatic Variables
SCRIPT_NAME=$(basename "$(dirname "$0")")
LOG_FILE="/tmp/user.scripts/tmpScripts/$SCRIPT_NAME/log.txt"

# 1. SILENT LOG CLEANUP (Self-clean)
if [ "$DEBUG" != "true" ] && [ -f "$LOG_FILE" ]; then
    : > "$LOG_FILE"
fi

echo "-------------------------------------------------------"
echo "🧹 Log Cleanup (Files older than $PURGE_DAYS days)"
echo ""

for FOLDER in $TARGET_PATHS; do
    if [ -d "$FOLDER" ]; then
        echo "📂 Searching: $FOLDER"
        echo ""
        
        # Using -atime (Access Time) per your purge variable
        # The logic captures .log, .log.gz, .log.1, .log.old, .bak, etc.
        find "$FOLDER" -type f -atime +"$PURGE_DAYS" \( -name "*.log" -o -name "*.log.*" -o -name "*.bak" \) -exec bash -c '
            for file do
                ACC=$(stat -c "%x" "$file" | cut -d"." -f1)
                echo "🗑️ Deleting: $file"
                echo "👁️ Last Access: $ACC"
                rm -f "$file"
                echo ""
            done
        ' bash {} +
    else
        echo "⚠️ Folder not found: $FOLDER"
    fi
done

echo "✅ Log Cleanup Finished: $(date)"
echo "-------------------------------------------------------"
echo ""
