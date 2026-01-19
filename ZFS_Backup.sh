##################################################################
# ZFS backup using snapshots and replication to a local and remote pool.
# 
# HOW TO USE:
# Create a new "User Script" in Unraid and paste the code below.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---
# #!/bin/bash
#
# SOURCE_POOL="cache"
# DATASETS=("appdata")
#
# # Manual Sync Snapshot Retention
# KEEP_MANUAL="3"
#
# # Sanoid Retention Policy
# KEEP_HOURLY="24"
# KEEP_DAILY="7"
# KEEP_WEEKLY="4"
# KEEP_MONTHLY="3"
# KEEP_YEARLY="0"
#
# # Destinations
# RUN_LOCAL="yes"
# DEST_PARENT_LOCAL="local_pool/local_backup"
#
# RUN_REMOTE="yes" 
# DEST_PARENT_REMOTE="remote_pool/offsite_backups"
# REMOTE_USER="root"
# REMOTE_HOST="192.168.1.50"
#
# # Notifications ("all" or "error")
# NOTIFY_LEVEL="all"
#
# # System
# DEBUG=true
# SCRIPT_DIR="/dev/shm/scripts"
# SCRIPT="$SCRIPT_DIR/ZFS_Backup.sh"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/ZFS_Backup.sh"
#
# [[ "$DEBUG" == "true" ]] && rm -rf "$SCRIPT_DIR"
# mkdir -p "$SCRIPT_DIR"
# [[ -f "$SCRIPT" ]] || \
#    curl -s -fL "$URL" -o "$SCRIPT" || \
#    { echo "❌ Download Failed"; exit 1; }
# source "$SCRIPT"
#
##################################################################

#!/bin/bash

# TRACKING VARIABLES
SUCCESS_TOTAL=0
FAILURE_TOTAL=0
SUMMARY_LOG=""

# FUNCTIONS
unraid_notify() {
    local title_msg="$1"
    local message="$2"
    local severity="$3" 
    local bubble="$4"

    if [[ "$NOTIFY_LEVEL" == "all" || "$severity" != "normal" ]]; then
        /usr/local/emhttp/webGui/scripts/notify -s "$bubble $title_msg" -d "$message" -i "$severity"
    fi
}

create_sanoid_config() {
    local target_path="$1"
    local config_dir="$2"
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
    local mode="$1" 
    local src="$2"
    local dest_parent="$3"
    local ds_name="$4"

    local dest_full_path="${dest_parent}/${ds_name}"
    local target="$dest_full_path"
    [[ "$mode" == "remote" ]] && target="${REMOTE_USER}@${REMOTE_HOST}:${dest_full_path}"

    echo "🚀 Replicating ($mode) to $target..."
    
    /usr/local/sbin/syncoid -r --no-sync-snap --force-delete "$src" "$target"
    local status=$?

    if [ $status -ne 0 ]; then
        echo "⚠️ Sync failed ($mode). Attempting repair..."
        if [[ "$mode" == "local" ]]; then
            zfs receive -A "$dest_full_path" 2>/dev/null
            zfs destroy -r "$dest_full_path"
        else
            ssh "${REMOTE_USER}@${REMOTE_HOST}" "zfs receive -A $dest_full_path 2>/dev/null; zfs destroy -r $dest_full_path"
        fi
        /usr/local/sbin/syncoid -r --no-sync-snap "$src" "$target"
        return $?
    fi
    return 0
}

# MAIN EXECUTION LOGIC
for DS in "${DATASETS[@]}"; do
    SRC_DS="${SOURCE_POOL}/${DS}"
    TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
    MANUAL_SNAP="manual_sync_$TIMESTAMP"
    
    echo "----------------------------------------------------"
    echo "📦 Dataset: $SRC_DS"

    zfs snapshot -r "$SRC_DS@$MANUAL_SNAP"

    local_stat=0
    remote_stat=0
    ds_failed=false

    # --- Local Replication ---
    if [[ "$RUN_LOCAL" == "yes" ]]; then
        LOCAL_DS="${DEST_PARENT_LOCAL}/${DS}"
        if replicate_with_repair "local" "$SRC_DS" "$DEST_PARENT_LOCAL" "$DS"; then
            local_stat=1
            DST_RAM_LOCAL="/dev/shm/Sanoid/dst_local_${DS//\//_}"
            create_sanoid_config "$LOCAL_DS" "$DST_RAM_LOCAL"
            /usr/local/sbin/sanoid --configdir "$DST_RAM_LOCAL" --prune-snapshots --quiet
            rm -rf "$DST_RAM_LOCAL"
            zfs list -H -t snapshot -o name -S creation "$LOCAL_DS" | grep "@manual_sync_" | tail -n +$((KEEP_MANUAL + 1)) | xargs -I {} zfs destroy -r {} 2>/dev/null
        else
            ds_failed=true
        fi
    fi

    # --- Remote Replication ---
    if [[ "$RUN_REMOTE" == "yes" ]]; then
        if replicate_with_repair "remote" "$SRC_DS" "$DEST_PARENT_REMOTE" "$DS"; then
            remote_stat=1
        else
            ds_failed=true
        fi
    fi

    # --- Result Formatting for Notification ---
    L_ICON="➖"; [[ "$RUN_LOCAL" == "yes" ]] && { [[ $local_stat -eq 1 ]] && L_ICON="✅" || L_ICON="❌"; }
    R_ICON="➖"; [[ "$RUN_REMOTE" == "yes" ]] && { [[ $remote_stat -eq 1 ]] && R_ICON="✅" || R_ICON="❌"; }
    
    SUMMARY_LOG+="$DS: local $L_ICON remote $R_ICON\n"

    # --- Cleanup Source if at least one target succeeded ---
    if [[ $local_stat -eq 1 || $remote_stat -eq 1 ]]; then
        ((SUCCESS_TOTAL++))
        SRC_RAM="/dev/shm/Sanoid/src_${SRC_DS//\//_}"
        create_sanoid_config "$SRC_DS" "$SRC_RAM"
        /usr/local/sbin/sanoid --configdir "$SRC_RAM" --take-snapshots --prune-snapshots --quiet
        rm -rf "$SRC_RAM"
        zfs list -H -t snapshot -o name -S creation "$SRC_DS" | grep "@manual_sync_" | tail -n +$((KEEP_MANUAL + 1)) | xargs -I {} zfs destroy -r {} 2>/dev/null
    else
        ((FAILURE_TOTAL++))
    fi
done

# FINAL NOTIFICATION LOGIC
NOTIFY_TITLE="ZFS Backup"
NOTIFY_SEVERITY="normal"
NOTIFY_BUBBLE="🟢"

if [ "$FAILURE_TOTAL" -gt 0 ]; then
    if [ "$SUCCESS_TOTAL" -gt 0 ]; then
        NOTIFY_SEVERITY="warning"
        NOTIFY_BUBBLE="🟡"
    else
        NOTIFY_SEVERITY="alert"
        NOTIFY_BUBBLE="🔴"
    fi
fi

echo -e "📊 Final Summary:\n$SUMMARY_LOG"
unraid_notify "$NOTIFY_TITLE" "$SUMMARY_LOG" "$NOTIFY_SEVERITY" "$NOTIFY_BUBBLE"

echo "----------------------------------------------------"
echo "🚀 ZFS Backup Finished."
