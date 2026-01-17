##########################################################################
# CLOUDFLARE DDNS
# 
# HOW TO USE:
# Do not run this script directly. Instead, create a new "User Script" 
# in Unraid and paste the code below.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---
# #!/bin/bash
#
# CF_API_TOKEN="YOUR_TOKEN"
# ZONE_ID="YOUR_ZONE_ID"
# DOMAIN="example.com" or "*.example.com"
# TUNNEL="your-id.cfargotunnel.com"
#
# # HOME NETWORK
# HOME_ROUTER_IP="192.168.1.1"
#
# # OPTIONS (Use "true" to enable)
# PROXIED="false"
# CHANGE_DNS_RECORDS="true"
# CACHE_DIR="/dev/shm/Cloudflare"
# DEBUG="true"
#
# DIR="/dev/shm/scripts"
# SCRIPT="$DIR/Cloudflare_DDNS.sh"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/Cloudflare_DDNS.sh"
#
# [[ "$DEBUG" == "true" ]] && rm -rf "$DIR"
# mkdir -p "$DIR"
# [[ -f "$SCRIPT" ]] || \
#   curl -s -fL "$URL" -o "$SCRIPT" || \
#   { echo "❌ Download Failed"; exit 1; }
# source "$SCRIPT"
#
#########################################################################


#!/bin/bash

# Cache Setup
SAFE_NAME=$(echo "$DOMAIN" | sed 's/\*/wildcard/g; s/\./_/g')
IP_CACHE="$CACHE_DIR/${SAFE_NAME}.ip"
mkdir -p "$CACHE_DIR"

# ==========================================
# PRE-FLIGHT CHECKS
# ==========================================
if ! command -v jq &> /dev/null || ! command -v traceroute &> /dev/null; then
    echo "❌ Error: 'jq' or 'traceroute' is not installed."
    exit 1
fi

# ==========================================
# FUNCTIONS
# ==========================================

debug_log() {
    [ "$DEBUG" = "true" ] && echo -e "DEBUG: $1"
}

get_public_ip() { 
    curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -Po 'ip=\K.*'
}

is_cgnat() {
    local ip=$1
    local trace=$(traceroute -n -m 2 -q 1 "$ip" 2>/dev/null)
    debug_log "Traceroute result:\n$trace"
    
    # Get the IP from the first hop line
    local first_hop=$(echo "$trace" | awk 'NR==2 {print $2}')
    debug_log "First hop detected: $first_hop"

    # If the first hop IS our public IP, it's definitely Public.
    if [[ "$first_hop" == "$ip" ]]; then
        debug_log "Direct public hop detected. Skipping CGNAT checks."
        return 1 # False (Is not CGNAT)
    fi

    local found_ips=$(echo "$trace" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b")
    for found in $found_ips; do
        [[ "$found" == "$HOME_ROUTER_IP" ]] && continue
        if [[ $found =~ ^10\. ]] || [[ $found =~ ^192\.168\. ]] || \
           [[ $found =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
           [[ $found =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
            debug_log "Private signature found: $found"
            return 0 # True (Is CGNAT)
        fi
    done
    return 1 # False
}

get_cloudflare_state() {
    curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DOMAIN" \
         -H "Authorization: Bearer $CF_API_TOKEN" \
         -H "Content-Type: application/json" | \
         jq -r '.result[0] | "\(.id // "null")|\(.type // "null")|\(.content // "null")|\(.proxied | if . == null then "false" else . end)"'
}

upsert_record() {
    local method=$1 id=$2 type=$3 content=$4 proxy=$5
    curl -s -X "$method" "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$id" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$type\",\"name\":\"$DOMAIN\",\"content\":\"$content\",\"ttl\":1,\"proxied\":$proxy}"
}

#!/usr/bin/env bash

# ==========================================
# UNRAID NOTIFICATION FUNCTION
# ==========================================
unraid_notify() {
    local message="$1"
    local flag="$2" # "success" or "warning"

    [[ "$notification_type" == "none" ]] && return 0
    [[ "$notification_type" == "error" && "$flag" == "success" ]] && return 0

    local severity="normal"
    [[ "$flag" == "warning" ]] && severity="warning"

    if [ -f "/usr/local/emhttp/webGui/scripts/notify" ]; then
        /usr/local/emhttp/webGui/scripts/notify \
            -s "Cloudflare DDNS Update" \
            -d "$message" \
            -i "$severity"
    fi
}

# ==========================================
# MAIN EXECUTION
# ==========================================
main() {
    echo "🔍 DDNS Check: $DOMAIN"
    [ "$DEBUG" = "true" ] && rm -f "$IP_CACHE"

    CURRENT_IP=$(get_public_ip)
    [ -z "$CURRENT_IP" ] && { echo "❌ IP Fail"; return 1; }

    IFS='|' read -r CF_ID CF_TYPE CF_CONTENT CF_PROXIED <<< "$(get_cloudflare_state)"

    if [ "$DEBUG" != "true" ] && [[ -f "$IP_CACHE" ]] && [[ "$(cat "$IP_CACHE")" == "$CURRENT_IP" ]]; then
        echo "✅ IP unchanged: $CURRENT_IP"
        return 0
    fi

    if [ "$CHANGE_DNS_RECORDS" = "true" ] && is_cgnat "$CURRENT_IP"; then
        REQ_TYPE="CNAME"; REQ_CONTENT="$TUNNEL"; REQ_PROXY="true"
        echo "🔒 Mode: CGNAT. IP: $CURRENT_IP"
    else
        REQ_TYPE="A"; REQ_CONTENT="$CURRENT_IP"
        [ "$PROXIED" = "true" ] && REQ_PROXY="true" || REQ_PROXY="false"
        echo "🌐 Mode: Public. IP: $CURRENT_IP"
    fi

    # API Sync Logic
    if [ "$CF_ID" == "null" ] || [ "$CF_TYPE" != "$REQ_TYPE" ] || [ "$CF_CONTENT" != "$REQ_CONTENT" ] || [ "$CF_PROXIED" != "$REQ_PROXY" ]; then
        
        [ "$CHANGE_DNS_RECORDS" != "true" ] && [ "$CF_ID" != "null" ] && return 0

        local SHOULD_NOTIFY=false
        local MSG=""

        if [ "$CF_ID" == "null" ]; then
            echo "🆕 Creating new record..."
            METHOD="POST"; TARGET_ID=""; SHOULD_NOTIFY=true
            MSG="Created new $REQ_TYPE record for $DOMAIN (IP: $CURRENT_IP)."
        elif [ "$CF_TYPE" != "$REQ_TYPE" ]; then
            echo "🔄 Type change detected. Recreating..."
            curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CF_ID" \
                 -H "Authorization: Bearer $CF_API_TOKEN" > /dev/null
            METHOD="POST"; TARGET_ID=""; SHOULD_NOTIFY=true
            MSG="Switched $DOMAIN to $REQ_TYPE mode (IP: $CURRENT_IP)."
        else
            echo "🆙 Updating existing record..."
            METHOD="PUT"; TARGET_ID="$CF_ID"
            # SHOULD_NOTIFY stays false for standard IP updates
        fi
        
        RES=$(upsert_record "$METHOD" "$TARGET_ID" "$REQ_TYPE" "$REQ_CONTENT" "$REQ_PROXY")
        
        if [[ "$RES" == *"\"success\":true"* ]]; then
            echo "$CURRENT_IP" > "$IP_CACHE"
            # ONLY notify if it was a NEW record or a TYPE switch
            if [ "$SHOULD_NOTIFY" = true ]; then
                unraid_notify "$MSG" "success"
            fi
        else
            ERR=$(echo "$RES" | jq -r '.errors[0].message // "Unknown Error"')
            echo "❌ Update Failed: $ERR"
            unraid_notify "Cloudflare Update Failed for $DOMAIN: $ERR" "warning"
        fi
    else
        echo "$CURRENT_IP" > "$IP_CACHE"
        [ "$DEBUG" = "true" ] && echo "✅ DNS is already correct."
    fi
}

main
echo ""
