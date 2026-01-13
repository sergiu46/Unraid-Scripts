#########################################################################
# Unraid sensors in Home Assistant
# 
# HOW TO USE:
# Do not run this script directly. Instead, create a new "User Script" 
# in Unraid and paste the "Loader" code below. This keeps your 
# API tokens safe and local to your machine.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---
# #!/bin/bash
#
# # ID of the drives to be monitores
# drives=(
#     "THNSN5256GPUK_NVMe_TOSHIBA_256GB_XXXXXXXXXXX"
#     "WD_Elements_SE_2622_XXXXXXXXXXXXXXXXXXXXXXXX"
# )
#
# # Uncomment to enable debug mode
# #DEBUG=true
#
# # Define sensors directory
# SENSORS_DIR="/dev/shm/ha-sensors"
#
# # GitHub script
# DIR="/dev/shm/scripts"
# SCRIPT="$TEMP_DIR/HA-Sensors.sh"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/HA-Sensors.sh"
#
# # Download and execute script
# mkdir -p "$DIR"
# [[ "$DEBUG" == "true" ]] && rm -f "$SCRIPT" && rm -rf "$SENSORS_DIR"
# [[ -f "$SCRIPT" ]] || \
#     curl -s -fL "$URL" -o "$SCRIPT" || \
#     { echo "❌ Download Failed"; exit 1; }
# source "$SCRIPT"
#
#########################################################################

#!/bin/bash
# This script create a file for each sensor that you want to monitor in Home Assistant

echo
# Create sensors directory
mkdir -p "${SENSORS_DIR}"

# CPU Temp
sensors | awk '/CPU Temp/ {gsub(/[^0-9.]/, "", $3); print $3}' > "$SENSORS_DIR/cpu_temp"

# Memory usage
free | awk '/Mem:/ {printf "%.2f\n", $3/$2 * 100}' > "$SENSORS_DIR/memory_usage"

# Cache utilization
zpool list cache -o cap | tr '\n' ' ' | awk '{print $2}' | sed 's/%//' > "$SENSORS_DIR/cache_utilization"

# Array utilization
df -ht fuse.shfs | awk '$NF=="/mnt/user" {gsub("%","", $5); print $5}' > "$SENSORS_DIR/array_utilization"

# Save /tmp and /dev/shm size to individual files
du -s /tmp | awk '{printf "%.2f\n", $1/1024}' > "$SENSORS_DIR/tmp_size"
du -s /dev/shm | awk '{printf "%.2f\n", $1/1024}' > "$SENSORS_DIR/shm_size"

# Extract fan speeds and save each one to a separate file
sensors | awk '/Array Fan:/ {gsub(/[^0-9]/, "", $3); print $3 > "'"$SENSORS_DIR"'/Array_Fan_" NR}'


# Get drive temp and state
drive_temp_state() {
    local device_id=$1
    
    device=$(ls -l /dev/disk/by-id/ | grep -E "${device_id}" | awk '{print $NF}' | sed 's#.*/##' | head -1)
    drive_temp=0
    state="n/a"
    status="n/a"
    
    if [[ "$device" == "nvme"* ]]; then
        drive_temp=$(nvme smart-log "/dev/${device%n*}" 2>/dev/null | awk '/^temperature/ { t=$3; u=$4; if(u ~ /°F/) { printf "%.0f\n", (t-32)*5/9 } else { printf "%.0f\n", t } }' )
        
    else
        # Check drive state
        state=$(hdparm -C "/dev/${device}" 2>/dev/null | awk -F': ' '/drive state is:/ {print $2}' | xargs )
        
        if [[ "${state}" == "active/idle" ]]; then
            drive_temp=$(smartctl -A "/dev/$device" 2>/dev/null | awk '/Temperature_Celsius|Airflow_Temperature_C/ {print $10}')
            status="on"
            
        elif [[ "$state" == "standby" ]]; then
            status="off"
            
        elif [[ "$state" == "unknown" ]]; then
            drive_temp=$(smartctl -A "/dev/$device" 2>/dev/null | awk '/Temperature_Celsius/ {print $10}')
            
            # Check if drive is awake with smartctl
            is_awake=$(smartctl --nocheck standby -i /dev/${device} | grep 'Power mode is' | egrep -c 'ACTIVE|IDLE')
            if [[ "${is_awake}" == "1" ]]; then
                status="on"
            else 
                status="off"
            fi
        fi
    fi
    
    echo "$drive_temp" > "${SENSORS_DIR}/${device_id}_temp"
    echo "$status" > "${SENSORS_DIR}/${device_id}_status"
    
    # Debug
    [ "$DEBUG" = "true" ] && echo "$device | $state | $status | $drive_temp | $device_id"
}


# Process each drive
for device_id in "${drives[@]}"
do
    drive_temp_state "${device_id}"
done

echo
