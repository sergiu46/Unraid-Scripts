#!/bin/bash

SNIPPETS_URL="https://github.com/sergiu46/Unraid-Scripts/tree/main/NginX-Snippets"

USER=$(echo "$SNIPPETS_URL" | cut -d'/' -f4)
REPO=$(echo "$SNIPPETS_URL" | cut -d'/' -f5)
BRANCH=$(echo "$SNIPPETS_URL" | cut -d'/' -f7)
FOLDER=$(echo "$SNIPPETS_URL" | cut -d'/' -f8-)

API_URL="https://api.github.com/repos/$USER/$REPO/contents/$FOLDER?ref=$BRANCH"

echo "Checking GitHub API for files in: $FOLDER..."

# Ensure local destination exists
mkdir -p "$SNIPPETS_DIR"

# Fetch the list of files and download each one
# We filter for 'download_url' to get the raw content link
FILE_LIST=$(curl -s "$API_URL")

if echo "$FILE_LIST" | grep -q '"message": "Not Found"'; then
    echo "❌ Error: Could not find GitHub folder. Check your GITHUB_URL."
    return 1
fi

# Loop through the files found in the folder
echo "$FILE_LIST" | grep -oP '"name": "\K[^"]+|"download_url": "\K[^"]+' | while read -r NAME; read -r RAW_URL; do
    if [[ "$RAW_URL" != "null" ]]; then
        echo "Updating: $NAME"
        curl -sSL "$RAW_URL" -o "$SNIPPETS_DIR/$NAME"
    fi
done

# Reload Nginx Proxy Manager
if docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    echo "Reloading $CONTAINER_NAME..."
    docker exec "$CONTAINER_NAME" nginx -s reload
    echo "✅ All snippets updated and Nginx reloaded."
else
    echo "⚠️ Warning: Container '$CONTAINER_NAME' is not running. Reload skipped."
fi
