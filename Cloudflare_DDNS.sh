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
# # --- AUTHENTICATION ---
# CF_API_TOKEN="YOUR_TOKEN"
# ZONE_ID="YOUR_ZONE_ID"
# DOMAIN="example.com"
#
# # --- NETWORK SETTINGS ---
# HOME_ROUTER_IP="192.168.1.1"
# TUNNEL="your-id.cfargotunnel.com"
# PROXIED="false"
#
# # --- BEHAVIOR ---
# CHANGE_DNS_RECORDS="true"  # "true" = Full Auto. "false" = Update IP only, BLOCK Mode Switches.
# NOTIFICATION_TYPE="all"    # Options: "all", "error", "none"
# DEBUG="false"              # Set to "true" to force update and clear cache
#
# # --- SYSTEM ---
# CACHE_DIR="/dev/shm/Cloudflare"
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

    local mode="${NOTIFICATION_TYPE:-all}"
    [[ "$mode" == "none" ]] && return 0
    [[ "$mode" == "error" && "$flag" == "success" ]] && return 0

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

    # FAST CACHE CHECK: Skip API if IP hasn't changed
    if [ "$DEBUG" != "true" ] && [[ -f "$IP_CACHE" ]] && [[ "$(cat "$IP_CACHE")" == "$CURRENT_IP" ]]; then
        echo "✅ IP unchanged ($CURRENT_IP). Skipping API check."
        return 0
    fi

    echo "🌐 IP Change/First Run detected ($CURRENT_IP). Syncing with Cloudflare..."
    IFS='|' read -r CF_ID CF_TYPE CF_CONTENT CF_PROXIED <<< "$(get_cloudflare_state)"

    # Determine required state
    if [ "$CHANGE_DNS_RECORDS" = "true" ] && is_cgnat "$CURRENT_IP"; then
        REQ_TYPE="CNAME"; REQ_CONTENT="$TUNNEL"; REQ_PROXY="true"
        echo "🔒 Mode: CGNAT"
    else
        REQ_TYPE="A"; REQ_CONTENT="$CURRENT_IP"
        [ "$PROXIED" = "true" ] && REQ_PROXY="true" || REQ_PROXY="false"
        echo "🌐 Mode: Public"
    fi

    # API Sync Logic
    if [ "$CF_ID" == "null" ] || [ "$CF_TYPE" != "$REQ_TYPE" ] || [ "$CF_CONTENT" != "$REQ_CONTENT" ] || [ "$CF_PROXIED" != "$REQ_PROXY" ]; then
        
        # --- SAFE MODE LOGIC ---
        if [ "$CHANGE_DNS_RECORDS" != "true" ] && [ "$CF_ID" != "null" ]; then
            if [ "$CF_TYPE" != "$REQ_TYPE" ]; then
                local BLOCK_MSG="UPDATE BLOCKED | $DOMAIN requires $REQ_TYPE mode but CHANGE_DNS_RECORDS is false."
                echo "⚠️ $BLOCK_MSG"
                unraid_notify "$BLOCK_MSG" "warning"
                echo "$CURRENT_IP" > "$IP_CACHE"
                return 0
            fi
        fi

        local SHOULD_NOTIFY=false
        local MSG=""

        if [ "$CF_ID" == "null" ]; then
            echo "🆕 Creating new record..."
            METHOD="POST"; TARGET_ID=""; SHOULD_NOTIFY=true
            MSG="NEW RECORD | Domain: $DOMAIN | Type: $REQ_TYPE | IP: $CURRENT_IP"
        elif [ "$CF_TYPE" != "$REQ_TYPE" ]; then
            echo "🔄 Type change detected. Recreating..."
            curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CF_ID" \
                 -H "Authorization: Bearer $CF_API_TOKEN" > /dev/null
            METHOD="POST"; TARGET_ID=""; SHOULD_NOTIFY=true
            MSG="TYPE SWITCH | Domain: $DOMAIN | Type: $REQ_TYPE | IP: $CURRENT_IP"
        else
            echo "🆙 Updating existing record..."
            METHOD="PUT"; TARGET_ID="$CF_ID"
        fi
        
        RES=$(upsert_record "$METHOD" "$TARGET_ID" "$REQ_TYPE" "$REQ_CONTENT" "$REQ_PROXY")
        
        if [[ "$RES" == *"\"success\":true"* ]]; then
            echo "✅ Success"
            echo "$CURRENT_IP" > "$IP_CACHE"
            [ "$SHOULD_NOTIFY" = true ] && unraid_notify "$MSG" "success"
        else
            ERR=$(echo "$RES" | jq -r '.errors[0].message // "Unknown Error"')
            echo "❌ Update Failed: $ERR"
            unraid_notify "Cloudflare Error | Domain: $DOMAIN | Message: $ERR" "warning"
        fi
    else
        echo "✅ Cloudflare matches. Syncing local cache."
        echo "$CURRENT_IP" > "$IP_CACHE"
    fi
}

main
echo ""
