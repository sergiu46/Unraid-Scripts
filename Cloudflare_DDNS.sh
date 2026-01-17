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
echo
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
    local found_ips=$(echo "$trace" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b")
    for found in $found_ips; do
        [[ "$found" == "$HOME_ROUTER_IP" ]] && continue
        if [[ $found =~ ^10\. ]] || [[ $found =~ ^192\.168\. ]] || \
           [[ $found =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
           [[ $found =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
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

# ==========================================
# MAIN
# ==========================================

main() {
    # 1. ALWAYS show the start of the check
    echo "🔍 DDNS Check: $DOMAIN"
    
    if [ "$DEBUG" = "true" ]; then
        echo "🧹 Debug Mode Active: Clearing cache..."
        rm -f "$IP_CACHE"
    fi

    CURRENT_IP=$(get_public_ip)
    [ -z "$CURRENT_IP" ] && { echo "❌ IP Fail"; exit 1; }

    # 2. ALWAYS show if the cache matches (Production Mode)
    if [ "$DEBUG" != "true" ]; then
        if [[ -f "$IP_CACHE" ]] && [[ "$(cat "$IP_CACHE")" == "$CURRENT_IP" ]]; then
            echo "✅ IP unchanged: $CURRENT_IP."
            exit 0
        fi
    fi

    # Determine required state
    if [ "$CHANGE_DNS_RECORDS" = "true" ] && is_cgnat "$CURRENT_IP"; then
        echo "🔒 Mode: CGNAT. IP: $CURRENT_IP."
        REQ_TYPE="CNAME"; REQ_CONTENT="$TUNNEL"; REQ_PROXY="true"
    else
        echo "🌐 Mode: Public. IP: $CURRENT_IP."
        REQ_TYPE="A"; REQ_CONTENT="$CURRENT_IP"
        [ "$PROXIED" = "true" ] && REQ_PROXY="true" || REQ_PROXY="false"
    fi

    # API Sync
    IFS='|' read -r CF_ID CF_TYPE CF_CONTENT CF_PROXIED <<< "$(get_cloudflare_state)"
    
    SUCCESS=false
    if [ "$CF_ID" == "null" ] || [ "$CF_TYPE" != "$REQ_TYPE" ] || [ "$CF_CONTENT" != "$REQ_CONTENT" ] || [ "$CF_PROXIED" != "$REQ_PROXY" ]; then
        
        if [ "$CHANGE_DNS_RECORDS" != "true" ]; then
            echo "⚠️ Mismatch detected, but CHANGE_DNS_RECORDS is not 'true'."
            echo "ℹ️  Cloudflare remains: $CF_TYPE -> $CF_CONTENT"
            echo "ℹ️  Detection found: $REQ_TYPE -> $REQ_CONTENT"
            exit 0
        fi

        echo "🆙 Updating Cloudflare..."
        if [ "$CF_TYPE" != "$REQ_TYPE" ] && [ "$CF_ID" != "null" ]; then
            curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$CF_ID" \
                 -H "Authorization: Bearer $CF_API_TOKEN" > /dev/null
            CF_ID=""; METHOD="POST"
        else
            METHOD="PUT"
        fi
        
        RES=$(upsert_record "$METHOD" "$CF_ID" "$REQ_TYPE" "$REQ_CONTENT" "$REQ_PROXY")
        [[ "$RES" == *"\"success\":true"* ]] && SUCCESS=true
    else
        # Only show this if we are specifically troubleshooting
        [ "$DEBUG" = "true" ] && echo "✅ DNS is already correct."
        SUCCESS=true
    fi

    if [ "$SUCCESS" = true ]; then
        echo "$CURRENT_IP" > "$IP_CACHE"
    else
        echo "❌ Update Failed: $RES"
    fi
}

main

echo
echo
