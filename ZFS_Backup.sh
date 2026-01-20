##################################################################
# ZFS backup using snapshots and replication to a local and remote pool.
#
# HOW TO USE:
# Create a new "User Script" in Unraid and paste the code below.
# Fill all variables with desired values.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---

# #!/bin/bash
#
# SOURCE_POOL="cache"
# DATASETS=( "appdata" "system" )
#
# # Destinations
# RUN_LOCAL="yes"
# EXCLUDE_LOCAL=()
# DEST_PARENT_LOCAL="local_pool/local_backup"
#
# RUN_REMOTE="yes"
# EXCLUDE_REMOTE=("system")
# DEST_PARENT_REMOTE="remote_pool/offsite_backups"
# REMOTE_USER="root"
# REMOTE_HOST="192.168.1.50"
#
# # Sanoid Retention Policy
# KEEP_MANUAL="2"
# KEEP_HOURLY="0"
# KEEP_DAILY="3"
# KEEP_WEEKLY="0"
# KEEP_MONTHLY="0"
# KEEP_YEARLY="0"
#
# # System
# # Debug "true" or "false" 
# # Notifications "all" or "error"
# DEBUG=false
# NOTIFY_LEVEL="error"
# SCRIPT_DIR="/dev/shm/scripts"
# SCRIPT="$SCRIPT_DIR/ZFS_Backup.sh"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/ZFS_Backup.sh"
#
# # Download script
# [[ "$DEBUG" == "true" ]] && rm -rf "$SCRIPT_DIR"
# mkdir -p "$SCRIPT_DIR"
# [[ -f "$SCRIPT" ]] || \
#   curl -s -fL "$URL" -o "$SCRIPT" || \
#   { echo "❌ Download Failed"; exit 1; }
# source "$SCRIPT"

##################################################################

#!/bin/bash

# TRACKING VARIABLES
SUCCESS_TOTAL=0
FAILURE_TOTAL=0
SUMMARY_LOG=""

# FUNCTIONS

unraid_notify() {
    local title_msg="$1"; local message="$2"; local severity="$3"; local bubble="$4"
    
    if [[ "$NOTIFY_LEVEL" == "all" || "$severity" != "normal" ]]; then
        # SHORT VERSION for WebUI (prevents cutoff/quotes)
        local web_msg="Backup Complete. See logs for details."
        
        /usr/local/emhttp/webGui/scripts/notify \
            -i "$severity" \
            -s "$bubble $title_msg" \
            -d "$web_msg" \
            -m "$(printf "%b" "$message")"
    fi
}

contains_element() {
    local e match="$1"; shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

create_sanoid_config() {
    local target_path="$1"; local config_dir="$2"
    mkdir -p "$config_dir"
    cp /etc/sanoid/sanoid.defaults.conf "$config_dir/sanoid.defaults.conf"
    cat <<EOF > "$config_dir/sanoid.conf"
[$target_path]
    use_template = production
    recursive = yes

[template_production]
    hourly = ${KEEP_HOURLY:-0}
    daily = ${KEEP_DAILY:-0}
    weekly = ${KEEP_WEEKLY:-0}
    monthly = ${KEEP_MONTHLY:-0}
    yearly = ${KEEP_YEARLY:-0}
    autosnap = yes
    autoprune = yes
EOF
}

replicate_with_repair() {
    local mode="$1"; local src="$2"; local dest_parent="$3"; local ds_name="$4"
    local dest_full_path="${dest_parent}/${ds_name}"
    local target="$dest_full_path"
    [[ "$mode" == "remote" ]] && target="${REMOTE_USER}@${REMOTE_HOST}:${dest_full_path}"

    echo "🚀 Replicating ($mode) to $target..."
    /usr/local/sbin/syncoid -r --no-sync-snap --force-delete "$src" "$target"
    local status=$?

    if [ $status -ne 0 ]; then
        echo "⚠️  Sync failed ($mode). Attempting repair..."
        if [[ "$mode" == "local" ]]; then
            zfs receive -A "$dest_full_path" 2>/dev/null; zfs destroy -r "$dest_full_path"
        else
            ssh "${REMOTE_USER}@${REMOTE_HOST}" "zfs receive -A $dest_full_path 2>/dev/null; zfs destroy -r $dest_full_path"
        fi
        echo "🔄 Retrying full sync..."
        /usr/local/sbin/syncoid -r --no-sync-snap "$src" "$target"
        return $?
    fi
    return 0
}

# MAIN EXECUTION
echo "----------------------------------------------------"
echo ""
echo "🛠️ ZFS Backup Started at $(date +%H:%M:%S)"
echo ""

for DS in "${DATASETS[@]}"; do
    SRC_DS="${SOURCE_POOL}/${DS}"
    TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
    MANUAL_SNAP="manual_sync_$TIMESTAMP"
    
    echo "----------------------------------------------------"
    echo "📦 Dataset: $SRC_DS"

    # 1. Take snapshot
    zfs snapshot -r "$SRC_DS@$MANUAL_SNAP" && echo "📸 Manual snapshot created: $MANUAL_SNAP"
    echo ""
    local_stat=0; remote_stat=0

    # 2. Local Backup Logic
    if [[ "$RUN_LOCAL" == "yes" ]]; then
        if contains_element "$DS" "${EXCLUDE_LOCAL[@]}"; then
            echo "⏭️  Skipping Local (Excluded)"
            echo ""
            local_stat=2
        else
            LOCAL_DS="${DEST_PARENT_LOCAL}/${DS}"
            if replicate_with_repair "local" "$SRC_DS" "$DEST_PARENT_LOCAL" "$DS"; then
                echo "✅ Local sync successful."
                echo ""
                local_stat=1
                DST_RAM_LOCAL="/dev/shm/Sanoid/dst_local_${DS//\//_}"
                create_sanoid_config "$LOCAL_DS" "$DST_RAM_LOCAL"
                /usr/local/sbin/sanoid --configdir "$DST_RAM_LOCAL" --prune-snapshots
                rm -rf "$DST_RAM_LOCAL"
            else
                local_stat=3
            fi
        fi
    fi

    # 3. Remote Backup Logic
    if [[ "$RUN_REMOTE" == "yes" ]]; then
        if contains_element "$DS" "${EXCLUDE_REMOTE[@]}"; then
            echo "⏭️  Skipping Remote (Excluded)"
            echo ""
            remote_stat=2
        else
            REMOTE_DS="${DEST_PARENT_REMOTE}/${DS}"
            if replicate_with_repair "remote" "$SRC_DS" "$DEST_PARENT_REMOTE" "$DS"; then
                echo "✅ Remote sync successful."
                echo ""
                remote_stat=1
            else
                remote_stat=3
            fi
        fi
    fi

    # 4. Result Text Mapping
    case $local_stat in
        1) L_RES="✅ Success" ;;
        2) L_RES="⏭️ Skipped" ;;
        3) L_RES="❌ Failed"  ;;
        *) L_RES="➖ Disabled" ;;
    esac

    case $remote_stat in
        1) R_RES="✅ Success" ;;
        2) R_RES="⏭️ Skipped" ;;
        3) R_RES="❌ Failed"  ;;
        *) R_RES="➖ Disabled" ;;
    esac
    
    # 5. Build Multi-line Card Summary
    SUMMARY_LOG+="\n📦 Dataset: $DS\n↳ 💾 Local: $L_RES\n↳ ☁️ Remote: $R_RES\n"

    # 6. Maintenance & Rotation (Source, Local, and Remote)
    if [[ $local_stat -eq 1 || $remote_stat -eq 1 ]]; then
        ((SUCCESS_TOTAL++))
        
        # Sanoid Maintenance for Source
        SRC_RAM="/dev/shm/Sanoid/src_${SRC_DS//\//_}"
        create_sanoid_config "$SRC_DS" "$SRC_RAM"
        /usr/local/sbin/sanoid --configdir "$SRC_RAM" --take-snapshots --prune-snapshots 
        rm -rf "$SRC_RAM"
        
        echo "🧹 Rotating manual snapshots..."

        # Rotate Source
        zfs list -H -t snapshot -o name -S creation "$SRC_DS" | grep "@manual_sync_" | tail -n +$((KEEP_MANUAL + 1)) | xargs -I {} zfs destroy -r {} 2>/dev/null
        
        # Rotate Local (if successful)
        if [[ $local_stat -eq 1 ]]; then
            zfs list -H -t snapshot -o name -S creation "$LOCAL_DS" | grep "@manual_sync_" | tail -n +$((KEEP_MANUAL + 1)) | xargs -I {} zfs destroy -r {} 2>/dev/null
        fi

        # Rotate Remote (if successful)
        if [[ $remote_stat -eq 1 ]]; then
            ssh "${REMOTE_USER}@${REMOTE_HOST}" "zfs list -H -t snapshot -o name -S creation '$REMOTE_DS' | grep '@manual_sync_' | tail -n +$((KEEP_MANUAL + 1)) | xargs -I {} zfs destroy -r {}" 2>/dev/null
        fi
        
        echo "✅ Rotation complete."
    else
        echo "❌ Both Local and Remote failed for $DS."
        ((FAILURE_TOTAL++))
    fi
done

# FINAL REPORT
NOTIFY_TITLE="ZFS Backup Report"
NOTIFY_SEVERITY="normal"; NOTIFY_BUBBLE="🟢"

if [ "$FAILURE_TOTAL" -gt 0 ]; then
    if [ "$SUCCESS_TOTAL" -gt 0 ]; then
        NOTIFY_SEVERITY="warning"; NOTIFY_BUBBLE="🟡"
    else
        NOTIFY_SEVERITY="alert"; NOTIFY_BUBBLE="🔴"
    fi
fi
echo "----------------------------------------------------"
echo ""
echo -e "📊 FINAL SUMMARY:\n$SUMMARY_LOG"
echo "----------------------------------------------------"
echo ""
echo "🚀 ZFS Backup Finished at $(date +%H:%M:%S)"
echo ""
echo "----------------------------------------------------"
unraid_notify "$NOTIFY_TITLE" "$SUMMARY_LOG" "$NOTIFY_SEVERITY" "$NOTIFY_BUBBLE"
