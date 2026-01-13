#########################################################################
# USB HDD spin down script.
# 
# HOW TO USE:
# Do not run this script directly. Instead, create a new "User Script" 
# in Unraid and paste the code below.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---
# #!/bin/bash
#
# # ID of the drives to be processed by script
# drives=(
#   "usb-WD_Elements_SE_0000_XXXXXXXXXXXXXXXXXXXXXXXX"
#   "usb-WD_Elements_SE_0000_XXXXXXXXXXXXXXXXXXXXXXXX"
#   "usb-WD_My_Passport_0000_XXXXXXXXXXXXXXXXXXXXXXXX"
# )
#
# # Uncomment to enable debug mode
# # DEBUG=true
#
# # Delay, hours and status dir
# DAY_DELAY=60
# NIGHT_DELAY=30
# DAY_HOUR='0900'
# NIGHT_HOUR='2200'
# STATUS_DIR="/dev/shm/hdd"
#
# # GitHub script
# DIR="/dev/shm/scripts"
# SCRIPT="$TEMP_DIR/HDD_Spindown_Logic.sh"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/USB_HDD_spin_down.sh"
#
# # Download and execute script
# mkdir -p "$DIR"
# [[ "$DEBUG" == "true" ]] && rm -f "$SCRIPT"
# [[ -f "$SCRIPT" ]] || \
#     curl -s -fL "$URL" -o "$SCRIPT" || \
#     { echo "❌ Download Failed"; exit 1; }
# source "$SCRIPT"
#
#########################################################################

#!/bin/bash

echo
# Determine Spindown Delay based on Time of Day
current_time="$(date +'%k%M')"
if [ "${current_time}" -ge "${DAY_HOUR}" ] && [ "${current_time}" -lt "${NIGHT_HOUR}" ]; then 
    SPINDOWN_DELAY=$DAY_DELAY
    MODE="DAY"
else
    SPINDOWN_DELAY=$NIGHT_DELAY
    MODE="NIGHT"
fi

# Set directory for status
mkdir -p "${STATUS_DIR}" 

current=`date`

do_device() {
    local device_id=$1
    device=`ls -l /dev/disk/by-id/ | grep ${device_id} | head -1 | tail -c4`
    filename="${STATUS_DIR}/diskaccess-${device_id}.status"

    # Check if the drive is awake or asleep
    is_awake=`smartctl --nocheck standby -i /dev/${device} | grep 'Power mode is' | egrep -c 'ACTIVE|IDLE'`

    if [ "${is_awake}" == "1" ]; then
        if [ "$DEBUG" = true ]; then
            echo "${device} is awake"
        fi

        stat_new=$(grep "${device} " /proc/diskstats | tr -dc "[:digit:]")

        if [ ! -f "${filename}" ]; then
            echo ${current} "- ${filename} file does not exist; creating it now."
            echo ${stat_new} > ${filename}
        else
            stat_old=`cat ${filename} | tr -dc "[:digit:]"`

            # Calculate time since last use
            current_time=$(date +%s)
            last_mod=$(stat ${filename} -c %Y)
            seconds_ago=$(expr $current_time - $last_mod)
            minutes_ago=$(expr $seconds_ago / 60)

            if [ "$DEBUG" = true ]; then
                echo "${device} old stat: ${stat_old}"
                echo "${device} new stat: ${stat_new}"
                echo "${device} new stat modified ${minutes_ago} minutes ago"
            fi

            if [ "${stat_old}" == "${stat_new}" ]; then
                if [ $minutes_ago -ge $SPINDOWN_DELAY ]; then
                    echo ${current} "- Drive /dev/${device} is awake and hasn't been used in ${minutes_ago} minutes; spinning down"
                    hdparm -y /dev/${device} > /dev/null 2>&1
                else
                    echo ${current} "- Drive /dev/${device} was last used ${minutes_ago} minutes ago, less than spindown setting ($SPINDOWN_DELAY)"
                fi
            else
                echo ${current} "- Drive /dev/${device} has been used..."
                echo ${stat_new} > ${filename}
            fi
        fi
    else
        if [ "$DEBUG" = true ]; then
            echo "${device} is asleep"
        fi
    fi
}

# Process each drive
for device_id in "${drives[@]}"
do
    do_device ${device_id}
done

echo

