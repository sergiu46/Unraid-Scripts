##########################################################################
# Authelia Config Sync Logic
# 
# HOW TO USE:
# 1. Create a new "User Script" in Unraid.
# 2. Copy the block below and paste it into the script editor.
# 3. Adjust variables (CONTAINER_NAME, CONFIG_DIR) if needed.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---

# #!/bin/bash
#
# # SETTINGS
# CONTAINER_NAME="Authelia"
# CONFIG_DIR="/mnt/user/appdata/Authelia"
#
# # Script config
# DEBUG="false"
# SCRIPT_DIR="/dev/shm/Authelia_Config"
# SCRIPT_URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/Authelia_Config.sh"
#
# # Download and execute logic
# [[ "$DEBUG" == "true" ]] && rm -rf "$SCRIPT_DIR"
# mkdir -p "$SCRIPT_DIR"
# curl -s -fL "$SCRIPT_URL" -o "$SCRIPT_DIR/Authelia_Config.sh" || \
# { echo "❌ Logic Download Failed"; exit 1; }
# source "$SCRIPT_DIR/Authelia_Config.sh"

# --- END COPY ---
#
#########################################################################


#!/bin/bash

# WAIT FOR INTERNET 
MAX_NET_RETRIES=15
NET_RETRY_COUNT=0
NET_WAIT_SECONDS=10
CHECK_HOST="1.1.1.1"

CONFIG_URL="https://github.com/sergiu46/Unraid-Scripts/tree/main/Authelia_Config"

echo "🔄 Update Authelia configuration."
echo ""

# --- WAIT FOR DOCKER SOCKET ---
echo "Waiting for Docker daemon..."
until [ -S /var/run/docker.sock ]; do
    sleep 1
done
echo "✅ Docker daemon is ready."

echo "Checking internet connectivity..."
while ! ping -c 1 -W 2 "$CHECK_HOST" > /dev/null 2>&1; do
    NET_RETRY_COUNT=$((NET_RETRY_COUNT + 1))
    if [ $NET_RETRY_COUNT -ge $MAX_NET_RETRIES ]; then
        echo "❌ Error: No internet connection detected after $((MAX_NET_RETRIES * NET_WAIT_SECONDS))s. Aborting."
        send_notification "Sync Aborted" "No internet connection detected. Check your network." "alert"
        exit 1
    fi
    echo "Waiting for internet... (Attempt $NET_RETRY_COUNT/$MAX_NET_RETRIES)"
    sleep $NET_WAIT_SECONDS
done
echo "✅ Internet connection established."


# Unraid Notification
send_notification() {
    local subject=$1
    local message=$2
    local importance=$3 # "normal" or "alert"

    # Logic: Always send alerts. Only send normal/success if DEBUG is true.
    if [[ "$importance" == "alert" ]] || [[ "$DEBUG" == "true" ]]; then
        /usr/local/emhttp/webGui/scripts/notify -e "Authelia Config Sync" -s "$subject" -d "$message" -i "$importance"
    fi
}

# Extract components from URL
USER=$(echo "$CONFIG_URL" | cut -d'/' -f4)
REPO=$(echo "$CONFIG_URL" | cut -d'/' -f5)
BRANCH=$(echo "$CONFIG_URL" | cut -d'/' -f7)
FOLDER=$(echo "$CONFIG_URL" | cut -d'/' -f8-)

API_URL="https://api.github.com/repos/$USER/$REPO/contents/$FOLDER?ref=$BRANCH"
BACKUP_DIR="$SCRIPT_DIR/Config_Backup"
NEW_TEMP="$SCRIPT_DIR/Config_New"

# WAIT FOR CONTAINER
MAX_RETRIES=10
RETRY_COUNT=0
WAIT_SECONDS=15

echo "Verifying $CONTAINER_NAME status..."
while ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "❌ Error: $CONTAINER_NAME failed to start. Aborting sync."
        send_notification "Sync Aborted" "Container $CONTAINER_NAME is not running. No files were modified." "alert"
        exit 1
    fi
    echo "Waiting for $CONTAINER_NAME to start (Attempt $RETRY_COUNT/$MAX_RETRIES)..."
    sleep $WAIT_SECONDS
done
echo "✅ $CONTAINER_NAME is online."

# WAIT FOR AUTHELIA TO INITIALIZE INSIDE CONTAINER
INIT_MAX_RETRIES=12
INIT_RETRY_COUNT=0
INIT_WAIT_SECONDS=5

echo "Waiting for Authelia to initialize inside $CONTAINER_NAME..."
while ! docker exec "$CONTAINER_NAME" authelia --config /config/configuration.yml validate-config > /dev/null 2>&1; do
    INIT_RETRY_COUNT=$((INIT_RETRY_COUNT + 1))
    if [ $INIT_RETRY_COUNT -ge $INIT_MAX_RETRIES ]; then
        echo "❌ Error: Authelia failed to initialize within $((INIT_MAX_RETRIES * INIT_WAIT_SECONDS))s. Aborting."
        send_notification "Sync Aborted" "Authelia process inside $CONTAINER_NAME failed to initialize in time." "alert"
        exit 1
    fi
    echo "Waiting for internal Authelia readiness (Attempt $INIT_RETRY_COUNT/$INIT_MAX_RETRIES)..."
    sleep $INIT_WAIT_SECONDS
done
echo "✅ Authelia is fully initialized. Proceeding with sync."

# BACKUP
if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$BACKUP_DIR" 
    mkdir -p "$BACKUP_DIR"
    cp -rp "$CONFIG_DIR/." "$BACKUP_DIR/"
    echo "📦 Local backup created."
fi

mkdir -p "$CONFIG_DIR"

# --- STEP 2: FETCH FILE LIST ---
FILE_LIST=$(curl -s "$API_URL")
if echo "$FILE_LIST" | grep -q '"message": "Not Found"'; then
    echo "❌ Error: GitHub folder not found."
    send_notification "Sync Failed" "GitHub folder not found. Check URL." "alert"
    exit 1
fi

# DOWNLOAD & SYNC
rm -rf "$NEW_TEMP" && mkdir -p "$NEW_TEMP"

# Robust JSON parser targeting only actual files
if command -v jq &> /dev/null; then
    echo "$FILE_LIST" | jq -r '.[] | select(.type == "file") | "\(.name) \(.download_url)"' | while read -r NAME RAW_URL; do
        if [[ -n "$NAME" && -n "$RAW_URL" ]]; then
            echo "Downloading: $NAME"
            curl -sSL "$RAW_URL" -o "$NEW_TEMP/$NAME"
        fi
    done
else
    # Fallback if jq is not present on the host
    echo "$FILE_LIST" | tr '}' '\n' | while read -r ITEM; do
        if echo "$ITEM" | grep -q '"type": "file"'; then
            NAME=$(echo "$ITEM" | grep -oP '"name": "\K[^"]+')
            RAW_URL=$(echo "$ITEM" | grep -oP '"download_url": "\K[^"]+')
            if [[ -n "$NAME" && -n "$RAW_URL" ]]; then
                echo "Downloading: $NAME"
                curl -sSL "$RAW_URL" -o "$NEW_TEMP/$NAME"
            fi
        fi
    done
fi

# Swap files to production (Safely overwrites only incoming files to protect untracked files)
cp -rp "$NEW_TEMP/." "$CONFIG_DIR/"

# SET PERMISSIONS
echo "Setting file permissions for $CONFIG_DIR..."
chown -R 99:100 "$CONFIG_DIR"
find "$CONFIG_DIR" -type d -exec chmod 755 {} \;
# Set standard files to 644 (Excludes any folder containing 'secret' and sensitive extensions)
find "$CONFIG_DIR" -type f -not -path "*/secret*/*" -not -name "*.db" -not -name "*.sqlite" -not -name "*secret*" -not -name "*.key" -not -name "*_key" -exec chmod 644 {} \;
# Set sensitive files to 600 (Includes any folder containing 'secret' and sensitive extensions)
find "$CONFIG_DIR" -type f \( -path "*/secret*/*" -o -name "*.db" -o -name "*.sqlite" -o -name "*secret*" -o -name "*.key" -o -name "*_key" \) -exec chmod 400 {} \;

# TEST & RESTART
echo "Testing Authelia configuration..."
if docker exec "$CONTAINER_NAME" authelia --config /config/configuration.yml validate-config > /dev/null 2>&1; then
    echo "✅ Config valid. Restarting Authelia container..."
    sleep 2
    docker restart "$CONTAINER_NAME"
    send_notification "Sync Successful" "Authelia configuration updated and container restarted." "normal"
    rm -rf "$BACKUP_DIR" "$NEW_TEMP"
else
    echo "❌ ERROR: New config INVALID. Rolling back..."
    send_notification "Update Failed - Rolling Back" "Invalid syntax in Authelia configuration. Reverted to backup." "alert"
    
    rm -rf "$CONFIG_DIR"/*
    [ -d "$BACKUP_DIR" ] && cp -rp "$BACKUP_DIR/." "$CONFIG_DIR/"
    rm -rf "$NEW_TEMP"
    exit 1
fi

echo ""


