#!/bin/bash

# --- HELPER: Unraid Notification ---
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

# --- STEP 0: WAIT FOR CONTAINER ---
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

# --- STEP 1: BACKUP ---
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

# --- STEP 3: DOWNLOAD & SYNC ---
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

# --- STEP 4: TEST & RELOAD ---
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
