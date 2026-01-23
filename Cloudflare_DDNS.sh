##########################################################################
# CLOUDFLARE DDNS
# 
# HOW TO USE:
# Create a new "User Script" in Unraid and paste the code below.
# Fill variables with desired values.


# --- COPY THIS TO UNRAID USER SCRIPTS ---
# #!/bin/bash
#
# # Cloudflare setup
# CF_API_TOKEN="YOUR_TOKEN"
# ZONE_ID="YOUR_ZONE_ID"
# DOMAIN="example.com"
# TUNNEL="your-id.cfargotunnel.com"
# PROXIED="false"
#
# # Behavior
# CHANGE_DNS_RECORDS="true"  # "true" = Full Auto. "false" = Update IP only, BLOCK Mode Switches.
# NOTIFICATION_TYPE="all"    # Options: "all", "error", "none"
# DEBUG="false"              # Set to "true" to bypass cache and show logs
#
# # Download script
# DIR="/dev/shm/scripts"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/Cloudflare_DDNS.sh"
#
# [[ "$DEBUG" == "true" ]] && rm -rf "$DIR"
# mkdir -p "$DIR"
# [[ -f "$DIR/Cloudflare_DDNS.sh" ]] || \
# curl -s -fL "$URL" -o "$DIR/Cloudflare_DDNS.sh" || \
# { echo "❌ Download Failed"; exit 1; }
# source "$DIR/Cloudflare_DDNS.sh"


#########################################################################

#!/bin/bash

# Cache Setup
CACHE_DIR="$DIR/cache"
SAFE_NAME=$(echo "$DOMAIN" | sed 's/\*/wildcard/g; s/\./_/g')
IP_CACHE="$CACHE_DIR/${SAFE_NAME}.ip"
mkdir -p "$CACHE_DIR"

# PRE-FLIGHT CHECKS
if ! command -v jq &> /dev/null || ! command -v traceroute &> /dev/null; then
    echo "❌ Error: 'jq' or 'traceroute' is not installed."
    exit 1
fi

# FUNCTIONS
debug_log() {
    [ "$DEBUG" = "true" ] && echo -e "🪲 $1"
}

get_public_ip() { 
    curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -Po 'ip=\K.*'
}

is_cgnat() {
    local ip=$1
    local trace=$(traceroute -n -m 2 -q 1 "$ip" 2>/dev/null)
    debug_log "Traceroute result:\n$trace"
    
    local first_hop=$(echo "$trace" | awk 'NR==2 {print $2}')
    debug_log "First hop detected: $first_hop"

    if [[ "$first_hop" == "$ip" ]]; then
        debug_log "Direct public hop detected. Skipping CGNAT checks."
        return 1 
    fi

    local found_ips=$(echo "$trace" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b")
    for found in $found_ips; do
        [[ "$found" == "$HOME_ROUTER_IP" ]] && continue
        if [[ $found =~ ^10\. ]] || [[ $found =~ ^192\.168\. ]] || \
           [[ $found =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
           [[ $found =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
            debug_log "Private signature found: $found"
            return 0 
        fi
    done
    return 1 
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

unraid_notify() {
    local message="$1"
    local flag="$2" 

    local mode="${NOTIFICATION_TYPE:-${notification_type:-all}}"
    
    [[ "$mode" == "none" ]] && return 0
    [[ "$mode" == "error" && "$flag" == "success" ]] && return 0

    local severity="normal"
    [[ "$flag" == "warning" ]] && severity="warning"

    if [ -f "/usr/local/emhttp/webGui/scripts/notify" ]; then
        /usr/local/emhttp/webGui/scripts/notify \
            -s "Cloudflare DDNS" \
            -d "$message" \
            -i "$severity"
    fi
}


# MAIN EXECUTION
main() {
    echo "🔍 DDNS Check: $DOMAIN"

    CURRENT_IP=$(get_public_ip)
    [ -z "$CURRENT_IP" ] && { echo "❌ IP Fail"; return 1; }

    # FAST CACHE CHECK
    if [ "$DEBUG" != "true" ] && [[ -f "$IP_CACHE" ]] && [[ "$(cat "$IP_CACHE")" == "$CURRENT_IP" ]]; then
        echo "✅ IP unchanged: $CURRENT_IP"
        return 0
    fi

    # Detect home router IP
    HOME_ROUTER_IP=$(ip route show default | awk '/default/ {print $3}')
    debug_log "Router IP:$HOME_ROUTER_IP"
    
   # ENHANCED CACHE & IP CHECK
    if [[ -f "$IP_CACHE" ]]; then
        OLD_IP=$(cat "$IP_CACHE")
        if [[ "$OLD_IP" == "$CURRENT_IP" ]]; then
            [ "$DEBUG" != "true" ] && echo "✅ IP unchanged: $CURRENT_IP" && return 0
        else
            echo "🔄 IP Change detected: $OLD_IP ⮕ $CURRENT_IP"
        fi
    else
        echo "🆕 IP Cached: $CURRENT_IP"
    fi

    # SYNC WITH CLOUDFLARE
    IFS='|' read -r CF_ID CF_TYPE CF_CONTENT CF_PROXIED <<< "$(get_cloudflare_state)"

    if [ "$CHANGE_DNS_RECORDS" = "true" ] && is_cgnat "$CURRENT_IP"; then
        REQ_TYPE="CNAME"; REQ_CONTENT="$TUNNEL"; REQ_PROXY="true"
        echo "🔒 Mode: CGNAT (CNAME required)"
    else
        REQ_TYPE="A"; REQ_CONTENT="$CURRENT_IP"
        [ "$PROXIED" = "true" ] && REQ_PROXY="true" || REQ_PROXY="false"
        echo "🌐 Mode: Public (A record required)"
    fi

    # COMPARE AND UPDATE
    if [ "$CF_ID" == "null" ] || [ "$CF_TYPE" != "$REQ_TYPE" ] || [ "$CF_CONTENT" != "$REQ_CONTENT" ] || [ "$CF_PROXIED" != "$REQ_PROXY" ]; then
        
        if [ "$CHANGE_DNS_RECORDS" != "true" ] && [ "$CF_ID" != "null" ] && [ "$CF_TYPE" != "$REQ_TYPE" ]; then
            local BLOCK_MSG="UPDATE BLOCKED | $DOMAIN requires $REQ_TYPE mode but Safe Mode is ON."
            echo "⚠️ $BLOCK_MSG"
            unraid_notify "$BLOCK_MSG" "warning"
            echo "$CURRENT_IP" > "$IP_CACHE"
            return 0
        fi

        local SHOULD_NOTIFY=false
        local MSG=""

        if [ "$CF_ID" == "null" ]; then
            echo "🆕 Creating new record..."
            METHOD="POST"; TARGET_ID=""; SHOULD_NOTIFY=true
            MSG="NEW RECORD | $DOMAIN | Type: $REQ_TYPE | IP: $CURRENT_IP"
        elif [ "$CF_TYPE" != "$REQ_TYPE" ]; then
            echo "🔄 Mode Switch detected..."
            curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CF_ID" \
                 -H "Authorization: Bearer $CF_API_TOKEN" > /dev/null
            METHOD="POST"; TARGET_ID=""; SHOULD_NOTIFY=true
            MSG="TYPE SWITCH | $DOMAIN | Type: $REQ_TYPE | IP: $CURRENT_IP"
        else
            echo "🆙 Updating IP address..."
            METHOD="PUT"; TARGET_ID="$CF_ID"
        fi
        
        RES=$(upsert_record "$METHOD" "$TARGET_ID" "$REQ_TYPE" "$REQ_CONTENT" "$REQ_PROXY")
        
        if [[ "$RES" == *"\"success\":true"* ]]; then
            echo "✅ Cloudflare updated successfully."
            echo "$CURRENT_IP" > "$IP_CACHE"
            [ "$SHOULD_NOTIFY" = true ] && unraid_notify "$MSG" "success"
        else
            ERR=$(echo "$RES" | jq -r '.errors[0].message // "Unknown Error"')
            echo "❌ Update Failed: $ERR"
            unraid_notify "Cloudflare Error | $DOMAIN | $ERR" "warning"
        fi
    else
        echo "✅ Cloudflare already matches current state."
        echo "$CURRENT_IP" > "$IP_CACHE"
    fi
}

main
echo ""
