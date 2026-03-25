##################################################################
# Rsync backup to a remote host.
# 
# HOW TO USE:
# Create a new "User Script" in Unraid and paste the code below.
# Fill variables with desired values.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---


# #!/bin/bash
#
# # List only the local folders to be backed up.
# LOCAL_FOLDERS=(
#     "/mnt/user/Pictures"
#     "/mnt/user/Videos"
# )
#
# # Remote config.
# REMOTE_HOST="192.168.1.50"
# REMOTE_USER="root"
# REMOTE_BASE_DIR="/mnt/user/Backup"
#
# # Script config. DEBUG "true" or "false". NOTIFY_LEVEL "all" or "error"
# DEBUG="false"
# NOTIFY_LEVEL="error"
# DIR="/dev/shm/Rsync_Backup"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/Rsync_Backup.sh"
#
# # Download and lock file
# [[ "$DEBUG" == "true" ]] && rm -rf "$DIR"
# mkdir -p "$DIR"
# [[ -f "$DIR/Rsync_Backup.sh" ]] || \
# curl -s -fL "$URL" -o "$DIR/Rsync_Backup.sh" || \
# { echo "❌ Download Failed"; exit 1; }
# exec 200>"$DIR/Rsync_Backup.lock" 
# flock -n 200 || \
# { echo "❌ Script already running"; exit 1; }
# source "$DIR/Rsync_Backup.sh"


##################################################################

#!/bin/bash

# --- INITIALIZATION ---
SUCCESS_TOTAL=0
FAILURE_TOTAL=0
SUMMARY_LOG=""

# Clean Logs
SCRIPT_NAME=$(basename "$(dirname "$0")")
LOG_FILE="/tmp/user.scripts/tmpScripts/$SCRIPT_NAME/log.txt"
if [ "$DEBUG" != "true" ] && [ -f "$LOG_FILE" ]; then
    : > "$LOG_FILE"
fi

# --- FUNCTIONS ---
unraid_notify() {
    local title_msg="$1"; local message="$2"; local severity="$3"; local bubble="$4"; local web_msg="$5"
    
    # Dacă web_msg lipsește, folosim titlul pentru descrierea scurtă
    [[ -z "$web_msg" ]] && web_msg="$title_msg"

    if [[ "$NOTIFY_LEVEL" == "all" || "$severity" != "normal" ]]; then
        /usr/local/emhttp/webGui/scripts/notify \
            -i "$severity" \
            -s "$bubble $title_msg" \
            -d "$web_msg" \
            -m "$message"
    fi
}

# --- MAIN EXECUTION ---
echo "----------------------------------------------------"
echo ""
echo "🛠️ Rsync Backup Started at $(date +'%H:%M:%S - %d.%m.%Y')"
echo ""
echo "----------------------------------------------------"

# 1. Verification Handshake
echo "🌐 Connecting to $REMOTE_HOST and verifying destination..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_USER@$REMOTE_HOST" "[ -d '$REMOTE_BASE_DIR' ]"; then
    echo "❌ Connection failed or Remote Directory '$REMOTE_BASE_DIR' missing."
    unraid_notify "Rsync Backup Failed!" "\nCannot reach $REMOTE_HOST or destination path is missing." "alert" "🔴" "Remote host unreachable."
    exit 1
fi
echo "✅ Remote path verified."


# 2. Backup Loop
for FOLDER in "${LOCAL_FOLDERS[@]}"; do
    FOLDER_NAME=$(basename "$FOLDER")
    echo "----------------------------------------------------"
    
    if [ ! -d "$FOLDER" ]; then
        echo "⚠️  Skipping: $FOLDER (Local path not found)"
        SUMMARY_LOG+="\n📂 $FOLDER_NAME\n↳ ⏭️ Not Found\n"
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
        SUMMARY_LOG+="\n📂 Folder: $FOLDER_NAME\n↳ ✅ Success\n"
        ((SUCCESS_TOTAL++))
    else
        echo "❌ Sync failed."
        SUMMARY_LOG+="\n📂 Folder: $FOLDER_NAME\n↳ ❌ Rsync Error\n"
        ((FAILURE_TOTAL++))
    fi
done

# 3. Report Generation
NOTIFY_TITLE="Rsync Backup Report"
NOTIFY_SEVERITY="normal"
NOTIFY_BUBBLE="🟢"
SHORT_MSG="All rsync backups completed successfully."

if [ "$FAILURE_TOTAL" -gt 0 ]; then
    if [ "$SUCCESS_TOTAL" -gt 0 ]; then
        NOTIFY_SEVERITY="warning"
        NOTIFY_BUBBLE="🟡"
        SHORT_MSG="Some rsync folders backup failed."
    else
        NOTIFY_SEVERITY="alert"
        NOTIFY_BUBBLE="🔴"
        SHORT_MSG="All rsync operations failed."
    fi
fi

echo "----------------------------------------------------"
echo ""
echo "📊 FINAL SUMMARY:"
echo -e "$SUMMARY_LOG"
echo "----------------------------------------------------"
echo ""
echo "🏁 Rsync Backup Finished at $(date +'%H:%M:%S - %d.%m.%Y')"
echo ""
echo "----------------------------------------------------"

# Final Notification Trigger
unraid_notify "$NOTIFY_TITLE" "$SUMMARY_LOG" "$NOTIFY_SEVERITY" "$NOTIFY_BUBBLE" "$SHORT_MSG"
