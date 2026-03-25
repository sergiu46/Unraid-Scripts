##########################################################################
# NginX Snippets Sync Logic
# 
# HOW TO USE:
# 1. Create a new "User Script" in Unraid.
# 2. Copy the block below and paste it into the script editor.
# 3. Adjust variables (CONTAINER_NAME, SNIPPETS_DIR) if needed.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---
#
# #!/bin/bash
#
# # --- SETTINGS ---
# CONTAINER_NAME="NPM-Official"
# SNIPPETS_DIR="/mnt/user/appdata/NPM-Official/data/nginx/snippets"
# SNIPPETS_URL="https://github.com/sergiu46/Unraid-Scripts/tree/main/NginX-Snippets"
#
# # Script config
# DEBUG="false"
# SCRIPT_DIR="/dev/shm/NginX-Snippets"
# SCRIPT_URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/NginX-Snippets.sh"
#
# # Download and execute logic
# [[ "$DEBUG" == "true" ]] && rm -rf "$SCRIPT_DIR"
# mkdir -p "$SCRIPT_DIR"
# curl -s -fL "$SCRIPT_URL" -o "$SCRIPT_DIR/NginX-Snippets.sh" || { echo "❌ Logic Download Failed"; exit 1; }
# source "$SCRIPT_DIR/NginX-Snippets.sh"
#
# --- END COPY ---
#
# NPM GUI CONFIGURATION:
# In the "Advanced" tab of your Proxy Host, use the following:
#
# Standard Host (No Authelia):
#
# location / {
#     include /data/nginx/snippets/proxy.conf;
#     proxy_pass $forward_scheme://$server:$port;
# }
#
# Host with Authelia Protection:
#
# include /data/nginx/snippets/authelia-location.conf;
#
# location / {
#     include /data/nginx/snippets/proxy.conf;
#     include /data/nginx/snippets/authelia-authrequest.conf;    
#     proxy_pass $forward_scheme://$server:$port;
# }
#
#########################################################################

#!/bin/bash

# WAIT FOR INTERNET 
MAX_NET_RETRIES=15
NET_RETRY_COUNT=0
NET_WAIT_SECONDS=10
CHECK_HOST="1.1.1.1"

echo "🔄 Update NginX snippets."
echo ""

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
        /usr/local/emhttp/webGui/scripts/notify -e "NPM Snippet Sync" -s "$subject" -d "$message" -i "$importance"
    fi
}

# Extract components from URL
USER=$(echo "$SNIPPETS_URL" | cut -d'/' -f4)
REPO=$(echo "$SNIPPETS_URL" | cut -d'/' -f5)
BRANCH=$(echo "$SNIPPETS_URL" | cut -d'/' -f7)
FOLDER=$(echo "$SNIPPETS_URL" | cut -d'/' -f8-)

API_URL="https://api.github.com/repos/$USER/$REPO/contents/$FOLDER?ref=$BRANCH"
BACKUP_DIR="$SCRIPT_DIR/Snippets_Backup"
NEW_TEMP="$SCRIPT_DIR/Snippets_New"

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
echo "✅ $CONTAINER_NAME is online. Proceeding with sync."

# BACKUP
if [ -d "$SNIPPETS_DIR" ]; then
    rm -rf "$BACKUP_DIR" 
    mkdir -p "$BACKUP_DIR"
    cp -rp "$SNIPPETS_DIR/." "$BACKUP_DIR/"
    echo "📦 Local backup created."
fi

mkdir -p "$SNIPPETS_DIR"

# --- STEP 2: FETCH FILE LIST ---
FILE_LIST=$(curl -s "$API_URL")
if echo "$FILE_LIST" | grep -q '"message": "Not Found"'; then
    echo "❌ Error: GitHub folder not found."
    send_notification "Sync Failed" "GitHub folder not found. Check URL." "alert"
    exit 1
fi

# DOWNLOAD & SYNC
rm -rf "$NEW_TEMP" && mkdir -p "$NEW_TEMP"

echo "$FILE_LIST" | grep -oP '"name": "\K[^"]+|"download_url": "\K[^"]+' | while read -r NAME; read -r RAW_URL; do
    if [[ "$RAW_URL" != "null" ]]; then
        echo "Downloading: $NAME"
        curl -sSL "$RAW_URL" -o "$NEW_TEMP/$NAME"
    fi
done

# Swap files to production
rm -rf "$SNIPPETS_DIR"/*
cp -rp "$NEW_TEMP/." "$SNIPPETS_DIR/"

# TEST & RELOAD
echo "Testing Nginx configuration..."
if docker exec "$CONTAINER_NAME" nginx -t > /dev/null 2>&1; then
    echo "✅ Config valid. Reloading..."
    docker exec "$CONTAINER_NAME" nginx -s reload
    send_notification "Sync Successful" "Snippets updated and $CONTAINER_NAME reloaded." "normal"
    rm -rf "$BACKUP_DIR" "$NEW_TEMP"
else
    echo "❌ ERROR: New config INVALID. Rolling back..."
    send_notification "Update Failed - Rolling Back" "Invalid syntax in GitHub snippets. Reverted to backup." "alert"
    
    rm -rf "$SNIPPETS_DIR"/*
    [ -d "$BACKUP_DIR" ] && cp -rp "$BACKUP_DIR/." "$SNIPPETS_DIR/"
    rm -rf "$NEW_TEMP"
    exit 1
fi

echo ""
