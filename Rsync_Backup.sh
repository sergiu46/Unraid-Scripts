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
# REMOTE_HOST="unraid.tail.ts.net"      # Your Tailscale IP
# REMOTE_USER="root"
# REMOTE_BASE_DIR="/mnt/user/Sergiu"
#
# # Set to "all" for a report every time, or "error" to only notify on failure
# NOTIFY_LEVEL="all"
#
# # System
# DEBUG=true
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

check_tailscale() {
    # We use REMOTE_HOST now. We cut to the first part (hostname) to grep status safely.
    local HOST_SHORT=$(echo "$REMOTE_HOST" | cut -d. -f1)
    echo "🌐 Checking Tailscale connection to $HOST_SHORT..."
    
    if tailscale status | grep -q "$HOST_SHORT"; then
        echo "✅ Tailscale is online."
        return 0
    else
        return 1
    fi
}

backup_remote() {
    local SRC="$1"
    local FOLDER_NAME=$(basename "$SRC")
    
    echo "----------------------------------------------------"
    echo "📦 Folder: $FOLDER_NAME"
    echo "🚀 Starting rsync to $REMOTE_USER@$REMOTE_HOST..."

    # Check if the remote base directory exists via SSH
    # Note: We use REMOTE_HOST here, not REMOTE_IP
    if ssh -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_HOST" "[ -d '$REMOTE_BASE_DIR' ]"; then
        
        # Perform rsync
        rsync -av --delete --timeout=30 "$SRC" "$REMOTE_USER@$REMOTE_HOST":"$REMOTE_BASE_DIR/"
        
        if [ $? -eq 0 ]; then
            echo "✅ Sync successful."
            SUMMARY_LOG+="📦 $FOLDER_NAME | ✅ Success
"
            ((SUCCESS_TOTAL++))
        else
            echo "❌ Sync failed during rsync."
            SUMMARY_LOG+="📦 $FOLDER_NAME | ❌ Rsync Error
"
            ((FAILURE_TOTAL++))
        fi
    else
        echo "❌ Sync failed: Remote directory not found."
        SUMMARY_LOG+="📦 $FOLDER_NAME | 📂 Remote Path Missing
"
        ((FAILURE_TOTAL++))
    fi
}

# --- MAIN EXECUTION ---

# Single line title
echo "🛠️ Remote Rsync Backup Started - $(date +%Y-%m-%d\ %H:%M:%S)"

# 1. Connectivity Check
if ! check_tailscale; then
    echo "❌ Tailscale is offline. Aborting."
    unraid_notify "Backup Aborted" "Tailscale is not connected to $REMOTE_HOST" "alert" "🔴"
    exit 1
fi

# 2. Iterate through the folder list
for FOLDER in "${LOCAL_FOLDERS[@]}"; do
    if [ -d "$FOLDER" ]; then
        backup_remote "$FOLDER"
    else
        echo "----------------------------------------------------"
        echo "⚠️  Skipping: $FOLDER (Not found)"
        SUMMARY_LOG+="📦 $(basename "$FOLDER") | ⏭️  Not Found
"
        ((FAILURE_TOTAL++))
    fi
done

# 3. Determine Final Status
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

# Print final logs to console
echo "----------------------------------------------------"
echo "📊 FINAL SUMMARY:"
echo -e "$SUMMARY_LOG"
echo "🏁 Rsync Backup Finished at $(date +%H:%M:%S)"
echo ""
# 4. Send the consolidated notification
unraid_notify "$NOTIFY_TITLE" "$SUMMARY_LOG" "$NOTIFY_SEVERITY" "$NOTIFY_BUBBLE"
