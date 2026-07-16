with open("README.md", "w", encoding="utf-8") as f:
    f.write("""# Unraid Automation & Administration Scripts

A collection of robust, production-grade Bash scripts for managing, automating, and backing up an Unraid homelab environment. 

These scripts are designed to be run via the **Unraid User Scripts plugin**. They utilize a dynamic execution architecture: the code pasted into Unraid is simply a lightweight wrapper that pulls the latest script logic directly from this repository into memory (`/dev/shm`) before execution. This ensures your server always runs the latest version without requiring manual updates in the Unraid GUI.

---

## 📜 Script Index

| Script | Category | Description |
| :--- | :--- | :--- |
| **`Authelia_Config.sh`** | Security / Docker | Fetches Authelia configurations from GitHub, validates syntax inside the running container, and safely applies/restarts with automated rollback on failure. |
| **`NginX_Snippets.sh`** | Networking / Docker | Syncs Nginx Proxy Manager snippets from GitHub, tests the configuration inside the active daemon, and reloads Nginx. |
| **`Cloudflare_DDNS.sh`** | Networking / DNS | Dynamic DNS updater for Cloudflare. Detects CGNAT to toggle between A records (Public IP) and CNAME records (Cloudflare Tunnels), bypassing Unraid cache safely. |
| **`deSEC.io_DDNS.sh`** | Networking / DNS | Updates root (`@`) and wildcard (`*`) A records for deSEC.io domains using the current public IP. |
| **`ZFS_Backup.sh`** | Backup / Storage | Advanced ZFS snapshot and replication using `syncoid`/`sanoid`. Syncs datasets to both local and remote ZFS pools with independent snapshot retention policies. |
| **`Rsync_Backup.sh`** | Backup / Storage | Mirrors local Unraid directories to a remote SSH target via `rsync`. Includes Unraid GUI notifications and detailed success/failure logging. |
| **`HA-Sensors.sh`** | Monitoring / IoT | Extracts Unraid hardware telemetry (CPU/Motherboard/NVMe/HDD temps, fan speeds, ZFS cache, Array utilization) into individual sensor files for Home Assistant ingestion. |
| **`USB_HDD_spin_down.sh`** | Hardware / Storage | Custom spin-down logic for USB-attached external hard drives (bypassing standard Unraid spin-down). Adjusts timeouts dynamically based on day and night hours. |
| **`Log_Cleanup.sh`** | Maintenance | Scans directories (like `/var/log` and `/dev/shm`) and purges files exceeding a specified access-time threshold to prevent memory exhaustion. |

---

## 🚀 How to Use

1. Install the **User Scripts** plugin from the Unraid Community Applications (CA) store.
2. Go to **Settings > User Scripts** and click **Add New Script**.
3. Name your script appropriately.
4. Open the script file you want to use from this repository (e.g., `ZFS_Backup.sh`).
5. Copy the heavily commented **Header Block** (the section between the `HOW TO USE` markers). It usually looks like this:
