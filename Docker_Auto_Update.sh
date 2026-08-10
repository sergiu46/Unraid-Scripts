# ==============================================================================
# Unraid Script: Docker auto-update with X days delay (Main Logic)
#
# HOW TO USE:
# 1. Create a new "User Script" in Unraid.
# 2. Copy the block below and paste it into the script editor.
# 3. Adjust variables (DELAY_DAYS, REMOVE_SKIPPED_IMAGE, NOTIFICATION_TYPE) if needed.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---


# #!/bin/bash
#
# # MINIMUM NUMBER OF DAYS SINCE RELEASE TO PERFORM THE UPDATE
# DELAY_DAYS=3
# # Remove newly pulled image if it doesn't meet the age requirement ("true" or "false")
# REMOVE_SKIPPED_IMAGE="true"
# # Prune orphan/dangling images left behind after container updates ("true" or "false")
# PRUNE_DANGLING="true"
# # Notification mode: "all", "updated", "error", or "none"
# NOTIFICATION_TYPE="all"
#
# # Script config. DEBUG "true" or "false".
# DIR="/dev/shm/docker_auto_update"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/Docker_Auto_Update.sh"
#
# # Download and execute script
# [[ "$DEBUG" == "true" ]] && rm -f "$DIR/Docker_Auto_Update.sh"
# mkdir -p "$DIR"
# [[ -f "$DIR/Docker_Auto_Update.sh" ]] || \
# curl -s -fL "$URL" -o "$DIR/Docker_Auto_Update.sh" || \
# { echo "❌ Download Failed"; exit 1; }
# source "$DIR/Docker_Auto_Update.sh"


# --- END COPY ---
#
# ==============================================================================

#!/bin/bash

UNRAID_UPDATE_SCRIPT="/usr/local/emhttp/plugins/dynamix.docker.manager/scripts/update_container"
REMOVE_SKIPPED_IMAGE="${REMOVE_SKIPPED_IMAGE:-true}"
PRUNE_DANGLING="${PRUNE_DANGLING:-true}"
NOTIFICATION_TYPE="${NOTIFICATION_TYPE:-all}"

# Tracking counters and details
UPDATED_COUNT=0
SKIPPED_COUNT=0
OK_COUNT=0
ERROR_COUNT=0

UPDATED_LIST=()
ERROR_LIST=()

unraid_notify() {
    local subject="$1"
    local message="$2"
    local severity="${3:-normal}"
    
    local mode="${NOTIFICATION_TYPE:-all}"
    
    [[ "$mode" == "none" ]] && return 0
    
    if [ -f "/usr/local/emhttp/webGui/scripts/notify" ]; then
        /usr/local/emhttp/webGui/scripts/notify \
            -s "$subject" \
            -d "$message" \
            -i "$severity"
    fi
}

echo "🚀 === Start Docker updates check (Release >= ${DELAY_DAYS:-3} days) ==="
echo "----------------------------------------------------------------------"

NOW_SEC=$(date +%s)
CONTAINERS=$(docker ps --format '{{.Names}}')

for CONTAINER in $CONTAINERS; do
    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")
    CURRENT_ID=$(docker inspect --format '{{.Image}}' "$CONTAINER")

    # Silently pull the latest version of the image
    docker pull "$IMAGE" > /dev/null 2>&1
    LATEST_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null)

    if [ -z "$LATEST_ID" ]; then
        echo "❌ [ERROR]    $CONTAINER - Could not verify the image."
        ERROR_COUNT=$((ERROR_COUNT + 1))
        ERROR_LIST+=("$CONTAINER: Could not verify image")
        continue
    fi

    # Check if there is a new version different from the current one
    if [ "$CURRENT_ID" != "$LATEST_ID" ]; then
        CREATED_DATE=$(docker image inspect --format '{{.Created}}' "$LATEST_ID")
        CREATED_SEC=$(date -d "$CREATED_DATE" +%s 2>/dev/null)

        if [ -n "$CREATED_SEC" ]; then
            AGE_SEC=$((NOW_SEC - CREATED_SEC))
            AGE_DAYS=$((AGE_SEC / 86400))

            if [ "$AGE_DAYS" -ge "${DELAY_DAYS:-3}" ]; then
                echo "🔄 [UPDATE]   $CONTAINER - New version ($AGE_DAYS days old). Updating..."
                if [ -f "$UNRAID_UPDATE_SCRIPT" ]; then
                    "$UNRAID_UPDATE_SCRIPT" "$CONTAINER" > /dev/null 2>&1
                    UPDATED_COUNT=$((UPDATED_COUNT + 1))
                    UPDATED_LIST+=("$CONTAINER ($AGE_DAYS days old)")
                else
                    echo "❌ [ERROR]    Unraid native script not found."
                    ERROR_COUNT=$((ERROR_COUNT + 1))
                    ERROR_LIST+=("$CONTAINER: Unraid update script missing")
                fi
            else
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                if [ "$REMOVE_SKIPPED_IMAGE" == "true" ]; then
                    echo "⏳ [SKIP]     $CONTAINER - New version available: $AGE_DAYS days (required: ${DELAY_DAYS:-3} days). Removing image."
                    docker image rm "$LATEST_ID" > /dev/null 2>&1
                else
                    echo "⏳ [SKIP]     $CONTAINER - New version available: $AGE_DAYS days (required: ${DELAY_DAYS:-3} days). Keeping image."
                fi
            fi
        else
            echo "❌ [ERROR]    $CONTAINER - Could not calculate release date for $IMAGE."
            ERROR_COUNT=$((ERROR_COUNT + 1))
            ERROR_LIST+=("$CONTAINER: Could not calculate release date")
        fi
    else
        echo "✅ [OK]       $CONTAINER - Already running the latest version."
        OK_COUNT=$((OK_COUNT + 1))
    fi
done

if [ "$PRUNE_DANGLING" == "true" ]; then
    echo "----------------------------------------------------------------------"
    echo "🧹 [CLEANUP]  Pruning orphan/dangling images..."
    docker image prune -f > /dev/null 2>&1
fi

echo "----------------------------------------------------------------------"
echo "🏁 === Check completed ==="
echo ""

# Process Notifications based on NOTIFICATION_TYPE
SHOULD_NOTIFY=false
NOTIF_SEVERITY="normal"

case "$NOTIFICATION_TYPE" in
    "all")
        SHOULD_NOTIFY=true
        [[ $ERROR_COUNT -gt 0 ]] && NOTIF_SEVERITY="warning"
        ;;
    "updated"|"info")
        if [ $UPDATED_COUNT -gt 0 ]; then
            SHOULD_NOTIFY=true
            NOTIF_SEVERITY="normal"
        fi
        ;;
    "error")
        if [ $ERROR_COUNT -gt 0 ]; then
            SHOULD_NOTIFY=true
            NOTIF_SEVERITY="warning"
        fi
        ;;
esac

if [ "$SHOULD_NOTIFY" = true ]; then
    NOTIF_BODY="Updated: $UPDATED_COUNT | Skipped: $SKIPPED_COUNT | OK: $OK_COUNT | Errors: $ERROR_COUNT"
    
    if [ ${#UPDATED_LIST[@]} -gt 0 ]; then
        NOTIF_BODY+=$'\n\n'
        NOTIF_BODY+="🔄 Updated:"
        for item in "${UPDATED_LIST[@]}"; do
            NOTIF_BODY+=$'\n'" • $item"
        done
    fi

    if [ ${#ERROR_LIST[@]} -gt 0 ]; then
        NOTIF_BODY+=$'\n\n'
        NOTIF_BODY+="❌ Errors:"
        for item in "${ERROR_LIST[@]}"; do
            NOTIF_BODY+=$'\n'" • $item"
        done
    fi

    unraid_notify "Docker Auto-Update" "$NOTIF_BODY" "$NOTIF_SEVERITY"
fi

# Cap log size.
MAX_LOG_LINES=${MAX_LOG_LINES:-1000}
SCRIPT_NAME=$(basename "$(dirname "$0")")
LOG_FILE="/tmp/user.scripts/tmpScripts/$SCRIPT_NAME/log.txt"

if [ -f "$LOG_FILE" ]; then
    CURRENT_LINES=$(wc -l < "$LOG_FILE")
    if [ "$CURRENT_LINES" -gt "$MAX_LOG_LINES" ]; then
        # Capture the last X lines
        tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp"
        # Overwrite the log file using cat to preserve the file descriptor
        cat "$LOG_FILE.tmp" > "$LOG_FILE"
        rm "$LOG_FILE.tmp"
        echo "✂️ Log capped to $MAX_LOG_LINES lines." >> "$LOG_FILE"
        echo ""
    fi
fi
