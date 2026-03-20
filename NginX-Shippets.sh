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

echo "Verifying container: $CONTAINER_NAME"

# Strict match: check if the exact name exists in the running container list
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container found. Testing Nginx configuration..."
    
    # Test config before reloading to prevent downtime
    if docker exec "$CONTAINER_NAME" nginx -t > /dev/null 2>&1; then
        echo "Configuration is valid. Reloading..."
        docker exec "$CONTAINER_NAME" nginx -s reload
        echo "✅ Success: All snippets updated and Nginx reloaded."
    else
        echo "❌ Error: Nginx config test failed! One of your snippets has an error."
        echo "Detailed Error Info:"
        docker exec "$CONTAINER_NAME" nginx -t
    fi
else
    echo "❌ Error: Container '$CONTAINER_NAME' not found among active containers."
    echo "Available containers identified:"
    docker ps --format '{{.Names}}'
fi
