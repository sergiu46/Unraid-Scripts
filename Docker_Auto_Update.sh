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
#      "example_container_1"
#      "example_container_2"
# )
#
# DELAY_DAYS=5
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

# ==============================================================================
# GLOBAL VARIABLES & CONFIGURATION
# ==============================================================================
DIR="${DIR:-/dev/shm/docker_auto_update}"
REGCTL_BIN="$DIR/regctl"
REGCTL_URL="https://github.com/regclient/regclient/releases/latest/download/regctl-linux-amd64"
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

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

echo "----------------------------------------------------"
echo ""
echo "🚀 Start Docker updates check (Release >= ${DELAY_DAYS:-3} days)"
echo ""
echo "----------------------------------------------------"

# Ensure regctl binary exists in the specified DIR
if [ ! -x "$REGCTL_BIN" ]; then
    echo "⏳ Downloading regctl binary to $DIR..."
    mkdir -p "$DIR"
    curl -sSL "$REGCTL_URL" -o "$REGCTL_BIN" && chmod +x "$REGCTL_BIN"
    if [ $? -ne 0 ]; then
        echo "❌ [ERROR] Failed to download regctl binary."
        exit 1
    fi
fi

NOW_SEC=$(date +%s)
CONTAINERS=$(docker ps --format '{{.Names}}')

for CONTAINER in $CONTAINERS; do
    # Check if container is in the exclusion list
    if contains_element "$CONTAINER" "${EXCLUDE_CONTAINERS[@]}"; then
        echo "⏭️ [EXCLUDED] $CONTAINER - Excluded from auto-updates."
        continue
    fi

    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")
    
    LOCAL_IMAGE_ID=$(docker inspect --format '{{.Image}}' "$CONTAINER")
    LOCAL_CREATED=$(docker inspect --format '{{.Created}}' "$LOCAL_IMAGE_ID" 2>/dev/null | tr -d '\r\n"')
    
    # Extract exact 19 characters (YYYY-MM-DDTHH:MM:SS), replace T with space, append UTC
    LOCAL_CLEAN=$(echo "$LOCAL_CREATED" | cut -c 1-19 | tr 'T' ' ')
    LOCAL_SEC=$(date -d "$LOCAL_CLEAN UTC" +%s 2>/dev/null)

    # Check remote image date using binary inside DIR (capturing stderr for debugging)
    REGCTL_ERR_FILE=$(mktemp)
    REMOTE_CREATED=$("$REGCTL_BIN" image inspect "$IMAGE" --format '{{.Created}}' 2> "$REGCTL_ERR_FILE" | tr -d '\r\n"')
    REGCTL_ERR_MSG=$(cat "$REGCTL_ERR_FILE" | tr -d '\r\n')
    rm -f "$REGCTL_ERR_FILE"

    if [ -z "$REMOTE_CREATED" ]; then
        echo "❌ [ERROR]    $CONTAINER - Could not verify remote image. Reason: ${REGCTL_ERR_MSG:-Unknown error}"
        ((ERROR_COUNT++))
        ERROR_LIST+=("$CONTAINER (Remote verification failed)")
        continue
    fi

    # Extract exact 19 characters (YYYY-MM-DD HH:MM:SS), replace T with space, append UTC
    REMOTE_CLEAN=$(echo "$REMOTE_CREATED" | cut -c 1-19 | tr 'T' ' ')
    REMOTE_SEC=$(date -d "$REMOTE_CLEAN UTC" +%s 2>/dev/null)

    if [ -n "$REMOTE_SEC" ] && [ -n "$LOCAL_SEC" ]; then
        # Check if remote image is newer than local image
        if [ "$REMOTE_SEC" -gt "$LOCAL_SEC" ]; then
            AGE_SEC=$((NOW_SEC - REMOTE_SEC))
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
                echo "⏳ [SKIP]     $CONTAINER - New version available: $AGE_DAYS days (required: ${DELAY_DAYS:-3} days). Skipping download."
            fi
        else
            echo "✅ [OK]       $CONTAINER - Already running the latest version."
        fi
    else
        echo "❌ [ERROR]    $CONTAINER - Date parsing failed. (Local: '$LOCAL_CREATED', Remote: '$REMOTE_CREATED')"
        ((ERROR_COUNT++))
        ERROR_LIST+=("$CONTAINER (Date calculation failed)")
    fi
done

if [ "$PRUNE_DANGLING" == "true" ]; then
    echo ""
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
echo ""
echo -e "FINAL SUMMARY:\n$STATS_LOG"
echo ""
echo "----------------------------------------------------"
echo ""
echo "🏁 Docker update check completed."
echo ""
echo "----------------------------------------------------"

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