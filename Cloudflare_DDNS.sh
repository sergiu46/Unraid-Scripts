#!/bin/bash

# Configurație
CF_API_TOKEN=""
ZONE_ID=""
RECORD_ID=""
DOMAIN="*.domain.com"

GET_RECORD_ID=true

# Get RECORD_ID
if [ "$GET_RECORD_ID" = true ]; then
    echo "Searching for Record ID for: $DOMAIN..."
    
    # Fetch records and use jq to filter for the specific domain name
    RESULT=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
         -H "Authorization: Bearer $CF_API_TOKEN" \
         -H "Content-Type: application/json")
    
    # This filters the JSON to show only the ID for your specific domain
    RECORD_ID=$(echo "$RESULT" | jq -r ".result[] | select(.name==\"$DOMAIN\") | .id")

    if [ ! -z "$RECORD_ID" ]; then
        echo "--------------------------------------------"
        echo "FOUND RECORD ID: $RECORD_ID"
        echo "--------------------------------------------"
        echo "Copy this ID to your RECORD_ID variable and set GET_RECORD_ID=false"
    else
        echo "Record not found. Here is the full list of records in this zone:"
        echo "$RESULT" | jq -r '.result[] | "\(.id) \t \(.type) \t \(.name)"'
    fi
    exit 0
fi

# 1. Get Public IP via Cloudflare Trace
# We use grep to extract just the IP address from the trace output
IP=$(curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -Po 'ip=\K.*')

# Safety check: Stop if we couldn't get the IP
if [ -z "$IP" ]; then
    echo "Error: Could not retrieve public IP."
    exit 1
fi

# 2. Get current record details from Cloudflare
RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json")

# Extract the Record Type (A, CNAME, etc.) and current IP content
CURRENT_TYPE=$(echo "$RESPONSE" | jq -r '.result.type')
CURRENT_IP=$(echo "$RESPONSE" | jq -r '.result.content')

# 3. Check Record Type
# If it is NOT an 'A' record (e.g., it is a CNAME for the Tunnel), stop here.
if [ "$CURRENT_TYPE" != "A" ]; then
  echo "Tunnel Mode detected (Record Type: $CURRENT_TYPE)."
  exit 0
fi

# 4. Check IP Address
# If the record is an 'A' type but the IP has changed, update it.
if [ "$IP" != "$CURRENT_IP" ]; then
  echo "IP mismatch detected. Updating Cloudflare..."
  
  curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"type":"A","name":"'"$DOMAIN"'","content":"'"$IP"'","ttl":1,"proxied":false}' \
    > /dev/null 2>&1
    
  echo "IP updated to $IP"
else
  echo "IP is up to date: $IP"
fi
