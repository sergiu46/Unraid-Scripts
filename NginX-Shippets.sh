#!/bin/bash

SNIPPETS_URL="https://github.com/sergiu46/Unraid-Scripts/tree/main/NginX-Snippets"

USER=$(echo "$SNIPPETS_URL" | cut -d'/' -f4)
REPO=$(echo "$SNIPPETS_URL" | cut -d'/' -f5)
BRANCH=$(echo "$SNIPPETS_URL" | cut -d'/' -f7)
FOLDER=$(echo "$SNIPPETS_URL" | cut -d'/' -f8-)

API_URL="https://api.github.com/repos/$USER/$REPO/contents/$FOLDER?ref=$BRANCH"

BACKUP_DIR="$SCRIPT_DIR/Snippets_Backup"

echo "Checking GitHub API for files in: $FOLDER..."

# 1. Create a local backup of current snippets if they exist
if [ -d "$SNIPPETS_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    cp -r "$SNIPPETS_DIR/." "$BACKUP_DIR/"
    echo "📦 Local backup created in $BACKUP_DIR"
fi

# Ensure local destination exists
mkdir -p "$SNIPPETS_DIR"

# 2. Fetch file list from GitHub
FILE_LIST=$(curl -s "$API_URL")

if echo "$FILE_LIST" | grep -q '"message": "Not Found"'; then
    echo "❌ Error: Could not find GitHub folder. Check your URL."
    return 1
fi

# 3. Download new files
echo "$FILE_LIST" | grep -oP '"name": "\K[^"]+|"download_url": "\K[^"]+' | while read -r NAME; read -r RAW_URL; do
    if [[ "$RAW_URL" != "null" ]]; then
        echo "Downloading: $NAME"
        curl -sSL "$RAW_URL" -o "$SNIPPETS_DIR/$NAME"
    fi
done

# 4. Verification and Rollback Logic
echo "Verifying container: $CONTAINER_NAME"

if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Testing Nginx configuration with new files..."
    
    # Test the configuration
    if docker exec "$CONTAINER_NAME" nginx -t > /dev/null 2>&1; then
        echo "✅ Config is valid. Reloading Nginx..."
        docker exec "$CONTAINER_NAME" nginx -s reload
        echo "🚀 Update successful!"
        rm -rf "$BACKUP_DIR" # Clean up backup on success
    else
        echo "❌ ERROR: New configuration is INVALID!"
        echo "Restoring backup and rolling back..."
        
        # Rollback: Delete the bad files and restore from backup
        rm -rf "$SNIPPETS_DIR"/*
        if [ -d "$BACKUP_DIR" ]; then
            cp -r "$BACKUP_DIR/." "$SNIPPETS_DIR/"
        fi
        
        echo "Showing Nginx error details:"
        docker exec "$CONTAINER_NAME" nginx -t
        echo "Reverting complete. Your Nginx is still running on the old config."
        exit 1
    fi
else
    echo "⚠️ Warning: Container '$CONTAINER_NAME' not running. Files updated but not verified/reloaded."
fi
