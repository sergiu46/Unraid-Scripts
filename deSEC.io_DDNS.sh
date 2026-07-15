#!/bin/bash
##########################################################################
# DESEC.IO DDNS
# 
# HOW TO USE:
# Create a new "User Script" in Unraid and paste the code below.
# Fill variables with desired values.
#########################################################################

# Cache Setup (RAM Disk)
DIR="${DIR:-/dev/shm/deSEC.io_DDNS}"
CACHE_DIR="$DIR/cache"
SAFE_NAME=$(echo "$DOMAIN" | sed 's/\*/wildcard/g; s/\./_/g')
IP_CACHE="$CACHE_DIR/${SAFE_NAME}.ip"
mkdir -p "$CACHE_DIR"

# PRE-FLIGHT CHECKS
if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
    echo "❌ Error: 'jq' or 'curl' is not installed."
    exit 1
fi

# FUNCTIONS
debug_log() {
    [ "$DEBUG" = "true" ] && echo -e "🪲 $1"
}

get_public_ip() {
    # Try to get Public IP from 3 different sources
    local ip=$(curl -s https://checkip.amazonaws.com || curl -s https://ifconfig.me || curl -s https://api.ipify.org)
    echo "$ip"
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
            -s "deSEC DDNS" \
            -d "$message" \
            -i "$severity"
    fi
}

update_desec_record() {
    local url_subname="$1"
    local payload_subname="$2"
    local ip="$3"
    local res
    
    res=$(curl -s -X PUT "https://desec.io/api/v1/domains/$DOMAIN/rrsets/$url_subname/A/" \
         --header "Authorization: Token $TOKEN" \
         --header "Content-Type: application/json" \
         --data "{\"subname\": \"$payload_subname\", \"type\": \"A\", \"records\": [\"$ip\"], \"ttl\": 3600}")
    
    echo "$res"
}

check_update_success() {
    local res="$1"
    local ip="$2"
    echo "$res" | jq -e ".records | contains([\"$ip\"])" &>/dev/null
}

extract_error() {
    local res="$1"
    local err
    err=$(echo "$res" | jq -r '.detail // (.non_field_errors | join(", ")) // (.records | join(", ")) // empty' 2>/dev/null)
    if [ -z "$err" ]; then
        err=$(echo "$res" | head -n 1 | cut -c1-100)
        [ -z "$err" ] && err="Empty response / network issue"
    fi
    echo "$err"
}

# MAIN EXECUTION
main() {
    echo "🔍 DDNS Check: $DOMAIN"

    CURRENT_IP=$(get_public_ip)
    if [ -z "$CURRENT_IP" ]; then
        echo "❌ Error: Could not detect Public IP. Check your Unraid internet connection."
        unraid_notify "deSEC Error | $DOMAIN | IP Detection Failed" "warning"
        return 1
    fi

    # FAST CACHE CHECK
    if [ "$DEBUG" != "true" ] && [[ -f "$IP_CACHE" ]] && [[ "$(cat "$IP_CACHE")" == "$CURRENT_IP" ]]; then
        echo "✅ IP unchanged: $CURRENT_IP"
        return 0
    fi

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

    local error_occurred=false

    # Update Root (@)
    echo "🆙 Updating root record..."
    RES_ROOT=$(update_desec_record "@" "" "$CURRENT_IP")
    if check_update_success "$RES_ROOT" "$CURRENT_IP"; then
         debug_log "Root record updated successfully."
    else
         echo "❌ Root Update Failed: $(extract_error "$RES_ROOT")"
         error_occurred=true
    fi

    # Update Wildcard (*)
    echo "🆙 Updating wildcard record..."
    RES_WILD=$(update_desec_record "*" "*" "$CURRENT_IP")
    if check_update_success "$RES_WILD" "$CURRENT_IP"; then
         debug_log "Wildcard record updated successfully."
    else
         echo "❌ Wildcard Update Failed: $(extract_error "$RES_WILD")"
         error_occurred=true
    fi

    if [ "$error_occurred" = false ]; then
        echo "✅ deSEC.io updated successfully."
        echo "$CURRENT_IP" > "$IP_CACHE"
        unraid_notify "IP UPDATED | $DOMAIN | IP: $CURRENT_IP" "success"
    else
        unraid_notify "deSEC Error | $DOMAIN | Check logs for details" "warning"
    fi
}

main
echo ""

# Cap log size
MAX_LOG_LINES=${MAX_LOG_LINES:-1000}
SCRIPT_NAME=$(basename "$(dirname "$0")")
LOG_FILE="/tmp/user.scripts/tmpScripts/$SCRIPT_NAME/log.txt"

if [ -f "$LOG_FILE" ]; then
    CURRENT_LINES=$(wc -l < "$LOG_FILE")
    if [ "$CURRENT_LINES" -gt "$MAX_LOG_LINES" ]; then
        tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp"
        cat "$LOG_FILE.tmp" > "$LOG_FILE"
        rm "$LOG_FILE.tmp"
        echo "✂️ Log capped to $MAX_LOG_LINES lines." >> "$LOG_FILE"
        echo ""
    fi
fi
