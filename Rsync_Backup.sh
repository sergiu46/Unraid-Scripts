##################################################################
# Rsync backup to a remote host.
# 
# HOW TO USE:
# Create a new "User Script" in Unraid and paste the code below.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---
# #!/bin/bash
#
# # List only the local folders you want to back up
# LOCAL_FOLDERS=(
#      "/mnt/user/Pictures"
#      "/mnt/user/Movies"
#      "/mnt/user/Personal"
# )
#
# # CONFIGURATION
# REMOTE_HOST="192.168.1.2"
# REMOTE_USER="root"
# REMOTE_BASE_DIR="/mnt/user/Sergiu"
#
# # Set to "all" for a report every time, or "error" to only notify on failure
# NOTIFY_LEVEL="all"
#
# # System
# # DEBUG=true
# SCRIPT_DIR="/dev/shm/scripts"
# SCRIPT="$SCRIPT_DIR/Rsync_Backup.sh"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/Rsync_Backup.sh"
#
# [[ "$DEBUG" == "true" ]] && rm -rf "$SCRIPT_DIR"
# mkdir -p "$SCRIPT_DIR"
# [[ -f "$SCRIPT" ]] || \
#    curl -s -fL "$URL" -o "$SCRIPT" || \
#    { echo "❌ Download Failed"; exit 1; }
# source "$SCRIPT"
##################################################################

#!/bin/bash

# --- INITIALIZATION ---
SUCCESS_TOTAL=0
FAILURE_TOTAL=0
SUMMARY_LOG=""

# --- FUNCTIONS ---
unraid_notify() {
    local title_msg="$1"
    local message="$2"
    local severity="$3" 
    local bubble="$4"
    
    if [[ "$NOTIFY_LEVEL" == "all" || "$severity" != "normal" ]]; then
        # SHORT VERSION for WebUI (prevents cutoff/quotes)
        local web_msg="Rsync Backup Complete. See logs for details."
        
        # FULL VERSION for Telegram/Email agents
        # Uses the -m flag for the long multi-line report
        /usr/local/emhttp/webGui/scripts/notify \
            -i "$severity" \
            -s "$bubble $title_msg" \
            -d "$web_msg" \
            -m "$(printf "%b" "$message")"
    fi
}

# --- MAIN EXECUTION ---
echo "🛠️ Rsync Backup Started at $(date +%H:%M:%S)"
echo ""

# 1. Verification Handshake
echo "🌐 Connecting to $REMOTE_HOST and verifying destination..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" "[ -d '$REMOTE_BASE_DIR' ]"; then
    echo "❌ Connection failed or Remote Directory '$REMOTE_BASE_DIR' missing."
    unraid_notify "Backup Aborted" "Cannot reach $REMOTE_HOST or destination path is missing." "alert" "🔴"
    exit 1
fi
echo "✅ Remote path verified."
echo ""

# 2. Backup Loop
for FOLDER in "${LOCAL_FOLDERS[@]}"; do
    FOLDER_NAME=$(basename "$FOLDER")
    echo "----------------------------------------------------"
    
    if [ ! -d "$FOLDER" ]; then
        echo "⚠️  Skipping: $FOLDER (Local path not found)"
        # Use \n for Telegram spacing
        SUMMARY_LOG+="\n📂 $FOLDER_NAME | ⏭️  Not Found\n"
        ((FAILURE_TOTAL++))
        continue
    fi

    echo "📂 Folder: $FOLDER_NAME"
    echo "🚀 Syncing to $REMOTE_HOST"
    echo ""
    
    # Mirror the local folder to the remote base directory
    rsync -av --delete --timeout=30 "$FOLDER" "$REMOTE_USER@$REMOTE_HOST":"$REMOTE_BASE_DIR/"
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Sync successful."
        SUMMARY_LOG+="\n📂 $FOLDER_NAME | ✅ Success\n"
        ((SUCCESS_TOTAL++))
    else
        echo "❌ Sync failed."
        SUMMARY_LOG+="\n📂 $FOLDER_NAME | ❌ Rsync Error\n"
        ((FAILURE_TOTAL++))
    fi
done

# 3. Report Generation
NOTIFY_TITLE="Rsync Backup Report"
NOTIFY_SEVERITY="normal"
NOTIFY_BUBBLE="🟢"

if [ "$FAILURE_TOTAL" -gt 0 ]; then
    if [ "$SUCCESS_TOTAL" -gt 0 ]; then
        NOTIFY_SEVERITY="warning"; NOTIFY_BUBBLE="🟡"
    else
        NOTIFY_SEVERITY="alert"; NOTIFY_BUBBLE="🔴"
    fi
fi

echo "----------------------------------------------------"
echo ""
echo "📊 FINAL SUMMARY:"
echo -e "$SUMMARY_LOG"
echo "🏁 Rsync Backup Finished at $(date +%H:%M:%S)"
echo ""

# Final Notification Trigger
# We add the leading \n here to ensure Telegram has that empty row after the title
unraid_notify "$NOTIFY_TITLE" "\n$SUMMARY_LOG" "$NOTIFY_SEVERITY" "$NOTIFY_BUBBLE"
