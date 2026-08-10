# ==============================================================================
# Unraid Script: Docker auto-update with X days delay (Main Logic)
#
# HOW TO USE:
# 1. Create a new "User Script" in Unraid.
# 2. Copy the block below and paste it into the script editor.
# 3. Adjust variables (DELAY_DAYS, REMOVE_SKIPPED_IMAGE, NOTIFICATION_TYPE, EXCLUDE_CONTAINERS) if needed.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---


# #!/bin/bash
#
# # Config
# EXCLUDE_CONTAINERS=(
#     "example_container_1"
#     "example_container_2"
# )
#
# DELAY_DAYS=5
# REMOVE_SKIPPED_IMAGE="true"
# PRUNE_DANGLING="true"
# NOTIFICATION_TYPE="all" # "all", "updated", "error", or "none"
#
# # Script config
# DEBUG="false"
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

# TRACKING VARIABLES
UPDATED_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

UPDATED_LIST=()
SKIPPED_LIST=()
ERROR_LIST=()

# Clean logs
SCRIPT_NAME=$(basename "$(dirname "$0")")
LOG_FILE="/tmp/user.scripts/tmpScripts/$SCRIPT_NAME/log.txt"
if [ "$DEBUG" != "true" ] && [ -f "$LOG_FILE" ]; then
    : > "$LOG_FILE"
fi

# FUNCTIONS
unraid_notify() {
    local title_msg="$1"; local message="$2"; local severity="$3"; local bubble="$4"; local web_msg="$5"
    
    if [ -f "/usr/local/emhttp/webGui/scripts/notify" ]; then
        /usr/local/emhttp/webGui/scripts/notify \
            -i "$severity" \
            -s "$bubble $title_msg" \
            -d "$web_msg" \
            -m "$(printf "%b" "$message")"
    fi
}

contains_element() {
    local e match="$1"; shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

# MAIN EXECUTION
echo "🚀 === Start Docker updates check (Release >= ${DELAY_DAYS:-3} days) ==="
echo "----------------------------------------------------------------------"

NOW_SEC=$(date +%s)
CONTAINERS=$(docker ps --format '{{.Names}}')

for CONTAINER in $CONTAINERS; do
    # Check if container is in the exclusion list
    if contains_element "$CONTAINER" "${EXCLUDE_CONTAINERS[@]}"; then
        echo "⏭️ [EXCLUDED] $CONTAINER - Excluded from auto-updates."
        continue
    fi

    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")
    CURRENT_ID=$(docker inspect --format '{{.Image}}' "$CONTAINER")

    # Silently pull the latest version of the image
    docker pull "$IMAGE" > /dev/null 2>&1
    LATEST_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null)

    if [ -z "$LATEST_ID" ]; then
        echo "❌ [ERROR]    $CONTAINER - Could not verify the image."
        ((ERROR_COUNT++))
        ERROR_LIST+=("$CONTAINER (Verification failed)")
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
                    ((UPDATED_COUNT++))
                    UPDATED_LIST+=("$CONTAINER ($AGE_DAYS days old)")
                else
                    echo "❌ [ERROR]    Unraid native script not found."
                    ((ERROR_COUNT++))
                    ERROR_LIST+=("$CONTAINER (Unraid script missing)")
                fi
            else
                ((SKIPPED_COUNT++))
                SKIPPED_LIST+=("$CONTAINER ($AGE_DAYS/${DELAY_DAYS:-3} days)")
                if [ "$REMOVE_SKIPPED_IMAGE" == "true" ]; then
                    echo "⏳ [SKIP]     $CONTAINER - New version available: $AGE_DAYS days (required: ${DELAY_DAYS:-3} days). Removing image."
                    docker image rm "$LATEST_ID" > /dev/null 2>&1
                else
                    echo "⏳ [SKIP]     $CONTAINER - New version available: $AGE_DAYS days (required: ${DELAY_DAYS:-3} days). Keeping image."
                fi
            fi
        else
            echo "❌ [ERROR]    $CONTAINER - Could not calculate release date for $IMAGE."
            ((ERROR_COUNT++))
            ERROR_LIST+=("$CONTAINER (Date calculation failed)")
        fi
    else
        echo "✅ [OK]       $CONTAINER - Already running the latest version."
    fi
done

if [ "$PRUNE_DANGLING" == "true" ]; then
    echo "----------------------------------------------------------------------"
    echo "🧹 [CLEANUP]  Pruning orphan/dangling images..."
    docker image prune -f > /dev/null 2>&1
fi

# FINAL REPORT
NOTIFY_TITLE="Docker Auto-Update"
NOTIFY_SEVERITY="normal"
NOTIFY_BUBBLE="🟢"
SHORT_MSG="Containers checked successfully!"

if [ "$ERROR_COUNT" -gt 0 ]; then
    if [ "$UPDATED_COUNT" -gt 0 ] || [ "$SKIPPED_COUNT" -gt 0 ]; then
        NOTIFY_SEVERITY="warning"
        NOTIFY_BUBBLE="🟡"
        SHORT_MSG="Updates completed with some errors!"
    else
        NOTIFY_SEVERITY="alert"
        NOTIFY_BUBBLE="🔴"
        SHORT_MSG="All update operations failed!"
    fi
elif [ "$UPDATED_COUNT" -gt 0 ]; then
    NOTIFY_SEVERITY="normal"
    NOTIFY_BUBBLE="🟢"
    SHORT_MSG="Successfully updated $UPDATED_COUNT container(s)!"
fi

# Build Notification Output
STATS_LOG="📊 Stats: $UPDATED_COUNT Updated | $SKIPPED_COUNT Skipped | $ERROR_COUNT Errors"
NOTIF_LOG="$STATS_LOG\n"

if [ ${#UPDATED_LIST[@]} -gt 0 ]; then
    NOTIF_LOG+="\n🔄 UPDATED:\n"
    for item in "${UPDATED_LIST[@]}"; do
        NOTIF_LOG+="  • $item\n"
    done
fi

if [ ${#SKIPPED_LIST[@]} -gt 0 ]; then
    NOTIF_LOG+="\n⏳ SKIPPED (Pending Age):\n"
    for item in "${SKIPPED_LIST[@]}"; do
        NOTIF_LOG+="  • $item\n"
    done
fi

if [ ${#ERROR_LIST[@]} -gt 0 ]; then
    NOTIF_LOG+="\n❌ ERRORS:\n"
    for item in "${ERROR_LIST[@]}"; do
        NOTIF_LOG+="  • $item\n"
    done
fi

# Terminal Final Summary
echo "----------------------------------------------------------------------"
echo ""
echo -e "FINAL SUMMARY:\n$STATS_LOG"
echo ""
echo "----------------------------------------------------------------------"
echo "🏁 === Check completed ==="
echo ""

# Process Notifications based on NOTIFICATION_TYPE
SHOULD_NOTIFY=false

if [[ "$NOTIFICATION_TYPE" != "none" ]]; then
    if [[ "$NOTIFICATION_TYPE" == "all" ]]; then
        SHOULD_NOTIFY=true
    elif [[ "$NOTIFICATION_TYPE" == "updated" && $UPDATED_COUNT -gt 0 ]]; then
        SHOULD_NOTIFY=true
    fi

    if [[ $ERROR_COUNT -gt 0 ]]; then
        SHOULD_NOTIFY=true
    fi

    if [[ "$SHOULD_NOTIFY" == "true" ]]; then
        unraid_notify "$NOTIFY_TITLE" "$NOTIF_LOG" "$NOTIFY_SEVERITY" "$NOTIFY_BUBBLE" "$SHORT_MSG"
    fi
fi

# Cap log size.
MAX_LOG_LINES=${MAX_LOG_LINES:-1000}
SCRIPT_NAME=$(basename "$(dirname "$0")")
LOG_FILE="/tmp/user.scripts/tmpScripts/$SCRIPT_NAME/log.txt"

if [ -f "$LOG_FILE" ]; then
    CURRENT_LINES=$(wc -l < "$LOG_FILE")
    if [ "$CURRENT_LINES" -gt "$MAX_LOG_LINES" ]; then
        tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp"
        cat "$LOG_FILE.tmp" > "$LOG_FILE"
        rm "$LOG_FILE.tmp"
        echo "✂️ Log capped to $MAX_LOG_LINES lines." >> "$LOG_FILE"
        echo ""
    fi
fi
