#!/bin/bash

# Extract components from URL
USER=$(echo "$SNIPPETS_URL" | cut -d'/' -f4)
REPO=$(echo "$SNIPPETS_URL" | cut -d'/' -f5)
BRANCH=$(echo "$SNIPPETS_URL" | cut -d'/' -f7)
FOLDER=$(echo "$SNIPPETS_URL" | cut -d'/' -f8-)

API_URL="https://api.github.com/repos/$USER/$REPO/contents/$FOLDER?ref=$BRANCH"

# Internal Temp Folders (inside SCRIPT_DIR)
BACKUP_DIR="$SCRIPT_DIR/Snippets_Backup"
NEW_TEMP="$SCRIPT_DIR/Snippets_New"

echo "Checking GitHub API for files in: $FOLDER..."

# 1. Create a local backup from the appdata directory
if [ -d "$SNIPPETS_DIR" ]; then
    rm -rf "$BACKUP_DIR" 
    mkdir -p "$BACKUP_DIR"
    cp -rp "$SNIPPETS_DIR/." "$BACKUP_DIR/"
    echo "📦 Local backup created in $BACKUP_DIR"
fi

# Ensure production destination exists
mkdir -p "$SNIPPETS_DIR"

# 2. Fetch file list from GitHub
FILE_LIST=$(curl -s "$API_URL")

if echo "$FILE_LIST" | grep -q '"message": "Not Found"'; then
    echo "❌ Error: Could not find GitHub folder. Check your URL."
    return 1
fi

# 3. Handle Updates
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    
    # Download to the temp folder inside SCRIPT_DIR
    rm -rf "$NEW_TEMP" && mkdir -p "$NEW_TEMP"

    echo "$FILE_LIST" | grep -oP '"name": "\K[^"]+|"download_url": "\K[^"]+' | while read -r NAME; read -r RAW_URL; do
        if [[ "$RAW_URL" != "null" ]]; then
            echo "Downloading: $NAME"
            curl -sSL "$RAW_URL" -o "$NEW_TEMP/$NAME"
        fi
    done

    # Move new files to production (Full Sync/Cleanup)
    rm -rf "$SNIPPETS_DIR"/*
    cp -rp "$NEW_TEMP/." "$SNIPPETS_DIR/"

    echo "Testing Nginx configuration with new files..."
    
    # 4. Test and Rollback
    if docker exec "$CONTAINER_NAME" nginx -t > /dev/null 2>&1; then
        echo "✅ Config is valid. Reloading Nginx..."
        docker exec "$CONTAINER_NAME" nginx -s reload
        echo "🚀 Update successful!"
        # Clean up temp folders on success
        rm -rf "$BACKUP_DIR" "$NEW_TEMP"
    else
        echo "❌ ERROR: New configuration is INVALID!"
        echo "Showing Nginx error details:"
        docker exec "$CONTAINER_NAME" nginx -t
        
        echo "Restoring backup and rolling back..."
        rm -rf "$SNIPPETS_DIR"/*
        if [ -d "$BACKUP_DIR" ]; then
            cp -rp "$BACKUP_DIR/." "$SNIPPETS_DIR/"
        fi
        
        echo "Reverting complete. Your Nginx is still running on the old config."
        rm -rf "$NEW_TEMP"
        exit 1
    fi
else
    echo "⚠️ Warning: Container '$CONTAINER_NAME' not running. Files updated but not verified."
fi
