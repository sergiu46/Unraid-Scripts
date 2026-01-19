##################################################################
# SOURCE_POOL="cache"
# DATASETS=("appdata")

# # Manual Sync Snapshot Retention
# # How many "manual_sync_" snapshots to keep on the source
# KEEP_MANUAL="3"

# # Sanoid Retention Policy (Defaults to 0 if left blank)
# KEEP_HOURLY="24"
# KEEP_DAILY="7"
# KEEP_WEEKLY="4"
# KEEP_MONTHLY="3"
# KEEP_YEARLY="0"

# # Destinations
# RUN_LOCAL="yes"
# DEST_PARENT_LOCAL="local_pool/local_backup"

# RUN_REMOTE="yes" 
# DEST_PARENT_REMOTE="remote_pool/offsite_backups"
# REMOTE_USER="root"
# REMOTE_HOST="192.168.1.50"
##################################################################

#!/bin/bash

# FUNCTIONS
unraid_notify() {
    local message="$1"
    local severity="$2" 
    /usr/local/emhttp/webGui/scripts/notify -s "ZFS Backup" -d "$message" -i "$severity"
}

create_sanoid_config() {
    local target_path="$1"
    local config_dir="$2"
    mkdir -p "$config_dir"
    cp /etc/sanoid/sanoid.defaults.conf "$config_dir/sanoid.defaults.conf"

    # Use :-0 to default to 0 if the variable is empty or undefined
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
        echo "⚠️  Sync failed ($mode). Attempting repair..."
        unraid_notify "⚠️ Out of sync detected on $mode ($ds_name). Repairing..." "warning"
        
        if [[ "$mode" == "local" ]]; then
            zfs destroy -r "$dest_full_path"
        else
            ssh "${REMOTE_USER}@${REMOTE_HOST}" "zfs destroy -r $dest_full_path"
        fi
        
        /usr/local/sbin/syncoid -r --no-sync-snap "$src" "$target"
        return $?
    fi
    return 0
}


#  MAIN EXECUTION LOGIC


for DS in "${DATASETS[@]}"; do
    SRC_DS="${SOURCE_POOL}/${DS}"
    TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
    MANUAL_SNAP="manual_sync_$TIMESTAMP"
    
    echo "----------------------------------------------------"
    echo "📦 Dataset: $SRC_DS"

    # 1. Create the new Manual Snapshot
    zfs snapshot -r "$SRC_DS@$MANUAL_SNAP"

    local_stat=1
    remote_stat=1

    # 2. Local Backup + Prune
    if [[ "$RUN_LOCAL" == "yes" ]]; then
        if replicate_with_repair "local" "$SRC_DS" "$DEST_PARENT_LOCAL" "$DS"; then
            local_stat=0
            DST_RAM_LOCAL="/dev/shm/Sanoid/dst_local_${DS//\//_}"
            create_sanoid_config "${DEST_PARENT_LOCAL}/${DS}" "$DST_RAM_LOCAL"
            /usr/local/sbin/sanoid --configdir "$DST_RAM_LOCAL" --prune-snapshots --quiet
            rm -rf "$DST_RAM_LOCAL"
        fi
    fi

    # 3. Remote Backup
    if [[ "$RUN_REMOTE" == "yes" ]]; then
        if replicate_with_repair "remote" "$SRC_DS" "$DEST_PARENT_REMOTE" "$DS"; then
            remote_stat=0
        fi
    fi

    # 4. Source Pruning & Manual Snapshot Cleanup
    if [[ $local_stat -eq 0 || $remote_stat -eq 0 ]]; then
        echo "✅ Backup success. Managing snapshots..."
        
        # A. Sanoid Pruning
        SRC_RAM="/dev/shm/Sanoid/src_${SRC_DS//\//_}"
        create_sanoid_config "$SRC_DS" "$SRC_RAM"
        /usr/local/sbin/sanoid --configdir "$SRC_RAM" --take-snapshots --prune-snapshots --quiet
        rm -rf "$SRC_RAM"

        # B. Manual Snapshot Rotation
        # Lists manual snapshots, skips the newest X (KEEP_MANUAL), and deletes the rest
        echo "🧹 Rotating manual snapshots (keeping $KEEP_MANUAL)..."
        zfs list -H -t snapshot -o name -S creation "$SRC_DS" | grep "@manual_sync_" | tail -n +$((KEEP_MANUAL + 1)) | xargs -I {} zfs destroy -r {}
        
        unraid_notify "✅ Success: $DS backed up." "normal"
    else
        unraid_notify "❌ Error: Backup failed for $DS." "alert"
    fi
done

echo "----------------------------------------------------"
echo "🚀 ZFS Backup Finished."
echo ""
