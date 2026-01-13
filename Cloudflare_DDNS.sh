#########################################################################
# CLOUDFLARE DDNS
# 
# HOW TO USE:
# Do not run this script directly. Instead, create a new "User Script" 
# in Unraid and paste the "Loader" code below. This keeps your 
# API tokens safe and local to your machine.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---
# #!/bin/bash
#
# CF_API_TOKEN="YOUR_TOKEN"
# ZONE_ID="YOUR_ZONE_ID"
# DOMAIN="example.com" or "*.example.com"
#
# # Uncomment to enable debug mode
# # DEBUG=true
#
# DIR="/dev/shm/scripts"
# SCRIPT="$DIR/Cloudflare_DDNS.sh"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/Cloudflare_DDNS.sh"
#
# mkdir -p "$DIR"
# [[ "$DEBUG" == "true" ]] && rm -f "$SCRIPT"
# [[ -f "$SCRIPT" ]] || \
#   curl -s -fL "$URL" -o "$SCRIPT" || \
#   { echo "❌ Download Failed"; exit 1; }
# source "$SCRIPT"
#
#########################################################################


#!/bin/bash

echo
echo Domain: ${DOMAIN}

# Cache settings in RAM
CACHE_DIR="/dev/shm/Cloudflare"
mkdir -p "$CACHE_DIR"
SAFE_NAME=$(echo "$DOMAIN" | sed 's/\*/wildcard/g; s/\./_/g')
CACHE_FILE="$CACHE_DIR/${SAFE_NAME}.id"

# Get Record ID from cache or Cloudflare API
[[ "$DEBUG" == "true" ]] && rm -f "$CACHE_FILE"
if [ -f "$CACHE_FILE" ]; then
    RECORD_ID=$(cat "$CACHE_FILE")
else
    echo "🔍 Searching for Record ID..."
    RESULT=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
         -H "Authorization: Bearer $CF_API_TOKEN" \
         -H "Content-Type: application/json")
    
    RECORD_ID=$(echo "$RESULT" | jq -r ".result[] | select(.name==\"$DOMAIN\") | .id" | head -n 1)

    if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
        echo "❌ Error: Record not found."
        exit 1
    fi
    echo "$RECORD_ID" > "$CACHE_FILE"
    echo "✅ Record ID cached: $RECORD_ID"
fi

# Get current public IP
IP=$(curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -Po 'ip=\K.*')
if [ -z "$IP" ]; then
    echo "❌ Error: Could not retrieve public IP."
    exit 1
fi

# Fetch current record status from Cloudflare
RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json")

CURRENT_TYPE=$(echo "$RESPONSE" | jq -r '.result.type')
CURRENT_IP=$(echo "$RESPONSE" | jq -r '.result.content')

#  If record is not 'A' (Tunnel mode), stop
if [ "$CURRENT_TYPE" != "A" ]; then
  echo "🛡️ Tunnel Mode active (Type: $CURRENT_TYPE). Skipping update."
  exit 0
fi

# Update IP if it has changed
if [ "$IP" != "$CURRENT_IP" ]; then
  echo "🔄 Updating IP: $CURRENT_IP -> $IP"
  curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"type":"A","name":"'"$DOMAIN"'","content":"'"$IP"'","ttl":1,"proxied":false}' > /dev/null 2>&1
  echo "✅ Success: IP updated!"
else
  echo "✅ IP is up to date: $IP"
fi
echo
