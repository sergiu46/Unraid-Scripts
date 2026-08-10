# ==============================================================================
# Unraid Script: Docker auto-update with X days delay (Main Logic)
#
# HOW TO USE:
# 1. Create a new "User Script" in Unraid.
# 2. Copy the block below and paste it into the script editor.
# 3. Adjust variables (DELAY_DAYS, CONFIG_DIR) if needed.
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
#
# # Script config. DEBUG "true" or "false".
# DIR="/dev/shm/docker_auto_update"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/Docker_Auto_Update.sh"
#
# # Download and execute script
# [[ "$DEBUG" == "true" ]] && rm -f "$DIR/Docker_Auto_Update.sh"
# mkdir -p "$DIR"
# [[ -f "$DIR/docker_auto_update.sh" ]] || \
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
        continue
    fi

    # Check if there is a new version different from the current one
    if [ "$CURRENT_ID" != "$LATEST_ID" ]; then
        CREATED_DATE=$(docker image inspect --format '{{.Created}}' "$LATEST_ID")
        CREATED_SEC=$(date -d "$CREATED_DATE" +%s 2>/dev/null)

        if [ -n "$CREATED_SEC" ]; then
            AGE_SEC=$((NOW_SEC - CREATED_SEC))
            AGE_DAYS=$((AGE_SEC / 86400))

            if [ "$AGE_DAYS" -ge "$DELAY_DAYS" ]; then
                echo "🔄 [UPDATE]   $CONTAINER - New version ($AGE_DAYS days old). Updating..."
                if [ -f "$UNRAID_UPDATE_SCRIPT" ]; then
                    "$UNRAID_UPDATE_SCRIPT" "$CONTAINER" > /dev/null 2>&1
                else
                    echo "❌ [ERROR]    Unraid native script not found."
                fi
            else
                if [ "$REMOVE_SKIPPED_IMAGE" == "true" ]; then
                    echo "⏳ [SKIP]     $CONTAINER - New version available: $AGE_DAYS days (required: $DELAY_DAYS days). Removing image."
                    docker image rm "$LATEST_ID" > /dev/null 2>&1
                else
                    echo "⏳ [SKIP]     $CONTAINER - New version available: $AGE_DAYS days (required: $DELAY_DAYS days). Keeping image."
                fi
            fi
        else
            echo "❌ [ERROR]    $CONTAINER - Could not calculate release date for $IMAGE."
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

echo "----------------------------------------------------------------------"
echo "🏁 === Check completed ==="
echo ""

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
