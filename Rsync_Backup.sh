##################################################################
# ZFS backup using snapshots and replication to a local and remote pool.
# 
# HOW TO USE:
# Create a new "User Script" in Unraid and paste the code below.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---
# #!/bin/bash
#
# # List only the local folders you want to back up
# LOCAL_FOLDERS=(
#     "/mnt/user/Pictures"
#     "/mnt/user/Movies"
#     "/mnt/user/Personal"
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
        /usr/local/emhttp/webGui/scripts/notify -s "$bubble $title_msg" -d "$message" -i "$severity"
    fi
}

# --- MAIN EXECUTION ---
echo "🛠️ Remote Rsync Backup Started - $(date +%Y-%m-%d\ %H:%M:%S)"
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
        SUMMARY_LOG+="📂 $FOLDER_NAME | ⏭️  Not Found
"
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
        SUMMARY_LOG+="📂 $FOLDER_NAME | ✅ Success
"
        ((SUCCESS_TOTAL++))
    else
        echo "❌ Sync failed."
        SUMMARY_LOG+="📂 $FOLDER_NAME | ❌ Rsync Error
"
        ((FAILURE_TOTAL++))
    fi
done

# 3. Report
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
unraid_notify "$NOTIFY_TITLE" "$SUMMARY_LOG" "$NOTIFY_SEVERITY" "$NOTIFY_BUBBLE"
