##################################################################
# Nextcloud daily maintenance (official docker image running as --user 99:100).
#   1. Fix file ownership/permissions if needed
#   2. Database maintenance (missing columns/indices/primary keys, bigint)
#   3. Scan user files
#
# HOW TO USE:
# Create a new "User Script" in Unraid and paste the code below.
# Fill variables with desired values.
#
# --- COPY THIS TO UNRAID USER SCRIPTS ---


# #!/bin/bash
#
# # Container config.
# CONTAINER="Nextcloud"
# OWNER_UID=99
# OWNER_GID=100
#
# # Host folders mounted into the container (code, apps, config).
# APP_DIRS=(
#     "/mnt/cache/appdata/Nextcloud/html"
#     "/mnt/cache/appdata/Nextcloud/apps"
#     "/mnt/cache/appdata/Nextcloud/config"
# )
# # Host folder with the user files (mounted at /var/www/html/data).
# DATA_DIR="/mnt/user/Nextcloud"
#
# # Tasks. "1" = run, "0" = skip.
# FIX_DATA=1          # Check data folder permissions (dirs 770, files 660)
# DB_MAINTENANCE=1    # Add missing columns/indices/primary keys, bigint conversion
# SCAN_FILES=1        # occ files:scan --all
#
# # Script config. DEBUG "true" or "false". NOTIFY_LEVEL "all" or "error"
# DEBUG="false"
# NOTIFY_LEVEL="error"
# DIR="/dev/shm/Nextcloud_Maintenance"
# URL="https://raw.githubusercontent.com/sergiu46/Unraid-Scripts/main/Nextcloud_Maintenance.sh"
#
# # Download and lock file
# [[ "$DEBUG" == "true" ]] && rm -rf "$DIR"
# mkdir -p "$DIR"
# [[ -f "$DIR/Nextcloud_Maintenance.sh" ]] || \
# curl -s -fL "$URL" -o "$DIR/Nextcloud_Maintenance.sh" || \
# { echo "❌ Download Failed"; exit 1; }
# exec 200>"$DIR/Nextcloud_Maintenance.lock"
# flock -n 200 || \
# { echo "❌ Script already running"; exit 1; }
# source "$DIR/Nextcloud_Maintenance.sh"


##################################################################

#!/bin/bash

# --- DEFAULTS (used if a variable is not passed by the wrapper) ---
CONTAINER="${CONTAINER:-Nextcloud}"
OWNER_UID="${OWNER_UID:-99}"
OWNER_GID="${OWNER_GID:-100}"
DATA_DIR="${DATA_DIR:-/mnt/user/Nextcloud}"
FIX_DATA="${FIX_DATA:-1}"
DB_MAINTENANCE="${DB_MAINTENANCE:-1}"
SCAN_FILES="${SCAN_FILES:-1}"
NOTIFY_LEVEL="${NOTIFY_LEVEL:-error}"

if [ ${#APP_DIRS[@]} -eq 0 ]; then
    APP_DIRS=(
        "/mnt/cache/appdata/Nextcloud/html"
        "/mnt/cache/appdata/Nextcloud/apps"
        "/mnt/cache/appdata/Nextcloud/config"
    )
fi

# --- INITIALIZATION ---
FAILED=0
PERM_FIXED=0
SUMMARY_LOG=""

# Clean Logs
SCRIPT_NAME=$(basename "$(dirname "$0")")
LOG_FILE="/tmp/user.scripts/tmpScripts/$SCRIPT_NAME/log.txt"
if [ "$DEBUG" != "true" ] && [ -f "$LOG_FILE" ]; then
    : > "$LOG_FILE"
fi

# --- FUNCTIONS ---
unraid_notify() {
    local title_msg="$1"; local message="$2"; local severity="$3"; local bubble="$4"; local web_msg="$5"

    [[ -z "$web_msg" ]] && web_msg="$title_msg"

    if [[ "$NOTIFY_LEVEL" == "all" || "$severity" != "normal" ]]; then
        /usr/local/emhttp/webGui/scripts/notify \
            -i "$severity" \
            -s "$bubble $title_msg" \
            -d "$web_msg" \
            -m "$(printf "%b" "$message")"
    fi
}

occ() {
    docker exec -u "$OWNER_UID" "$CONTAINER" php /var/www/html/occ "$@"
}

# Only changes what is wrong. $1 = folder, $2 = dir mode, $3 = file mode
fix_tree() {
    local d="$1" dm="$2" fm="$3" n_own n_dir n_file

    if [ ! -d "$d" ]; then
        echo "⚠️  Missing folder: $d"
        SUMMARY_LOG+="\n📂 $d\n↳ ⏭️ Not Found\n"
        FAILED=1
        return
    fi

    echo "📂 Checking: $d"

    n_own=$(find "$d" \( ! -uid "$OWNER_UID" -o ! -gid "$OWNER_GID" \) -print -exec chown -h "$OWNER_UID:$OWNER_GID" {} + 2>/dev/null | wc -l)
    echo "   👤 Owner fixed on $n_own item(s)"

    n_dir=$(find "$d" -type d ! -perm "$dm" -print -exec chmod "$dm" {} + 2>/dev/null | wc -l)
    echo "   📁 Directory mode fixed on $n_dir item(s)"

    # config.php is kept private (640) further below, so it is skipped here
    n_file=$(find "$d" -type f ! -perm "$fm" ! \( -path "$d/config.php" -o -path "$d/config/config.php" \) -print -exec chmod "$fm" {} + 2>/dev/null | wc -l)
    echo "   📄 File mode fixed on $n_file item(s)"

    PERM_FIXED=$((PERM_FIXED + n_own + n_dir + n_file))
    echo ""
}

finish() {
    local title="Nextcloud Maintenance"
    local severity="normal" bubble="🟢" short="Maintenance completed successfully."

    if [ "$FAILED" = 1 ]; then
        severity="warning"; bubble="🟡"; short="Maintenance finished with errors."
    fi

    echo "----------------------------------------------------"
    echo ""
    echo "📊 FINAL SUMMARY:"
    echo -e "$SUMMARY_LOG"
    echo "----------------------------------------------------"
    echo ""
    echo "🏁 Nextcloud Maintenance Finished at $(date +'%H:%M:%S - %d.%m.%Y')"
    echo ""
    echo "----------------------------------------------------"

    unraid_notify "$title" "$SUMMARY_LOG" "$severity" "$bubble" "$short"
    [ "$FAILED" = 1 ] && exit 1
    exit 0
}

abort() { # $1 = console message, $2 = short notification text
    echo "❌ $1"
    unraid_notify "Nextcloud Maintenance Failed!" "\n$1" "alert" "🔴" "$2"
    exit 1
}

# --- MAIN EXECUTION ---
echo "----------------------------------------------------"
echo ""
echo "🛠️ Nextcloud Maintenance Started at $(date +'%H:%M:%S - %d.%m.%Y')"
echo ""
echo "----------------------------------------------------"

# 1. Permissions
echo "🔐 Checking ownership and permissions..."
echo ""

for FOLDER in "${APP_DIRS[@]}"; do
    fix_tree "$FOLDER" 755 644
done

# config.php contains the database password: keep it private
for FOLDER in "${APP_DIRS[@]}"; do
    [ -d "$FOLDER" ] || continue
    find "$FOLDER" -maxdepth 2 -name config.php ! -perm 640 -exec chmod 640 {} + 2>/dev/null
done

if [ "$FIX_DATA" = 1 ]; then
    fix_tree "$DATA_DIR" 770 660
    if [ ! -f "$DATA_DIR/.ncdata" ]; then
        echo "⚠️  WARNING: $DATA_DIR/.ncdata is missing - wrong data folder?"
        SUMMARY_LOG+="\n⚠️ $DATA_DIR/.ncdata is missing\n"
        FAILED=1
    fi
fi
SUMMARY_LOG+="\n🔐 Permissions\n↳ ✅ $PERM_FIXED item(s) fixed\n"

# 2. Check that Nextcloud answers
echo "----------------------------------------------------"
echo "🌐 Checking container '$CONTAINER'..."

if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
    abort "Container '$CONTAINER' is not running - skipping database maintenance and scan." "Container is not running."
fi
if ! occ status >/dev/null 2>&1; then
    abort "occ does not respond - skipping database maintenance and scan. Check: docker logs $CONTAINER" "occ does not respond."
fi
if occ status --output=json 2>/dev/null | grep -Eq '"maintenance":[[:space:]]*true'; then
    abort "Maintenance mode is on (update running?) - skipping database maintenance and scan." "Nextcloud is in maintenance mode."
fi
echo "✅ Nextcloud is responding."

# 3. Database maintenance
if [ "$DB_MAINTENANCE" = 1 ]; then
    echo "----------------------------------------------------"
    echo "🗄️ Database maintenance"
    echo ""

    for CMD in \
        "db:add-missing-columns" \
        "db:add-missing-indices" \
        "db:add-missing-primary-keys" \
        "db:convert-filecache-bigint --no-interaction"
    do
        echo "▶️ occ $CMD"
        # shellcheck disable=SC2086
        if occ $CMD; then
            SUMMARY_LOG+="\n🗄️ occ $CMD\n↳ ✅ Success\n"
        else
            echo "❌ Failed: occ $CMD"
            SUMMARY_LOG+="\n🗄️ occ $CMD\n↳ ❌ Failed\n"
            FAILED=1
        fi
        echo ""
    done
fi

# 4. Scan user files
if [ "$SCAN_FILES" = 1 ]; then
    echo "----------------------------------------------------"
    echo "🔎 Scanning user files"
    echo ""

    if occ files:scan --all; then
        echo ""
        echo "✅ Scan successful."
        SUMMARY_LOG+="\n🔎 occ files:scan --all\n↳ ✅ Success\n"
    else
        echo ""
        echo "❌ Scan failed."
        SUMMARY_LOG+="\n🔎 occ files:scan --all\n↳ ❌ Failed\n"
        FAILED=1
    fi
fi

# 5. Report
finish
