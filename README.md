# Unraid Automation & Administration Scripts

A collection of robust, production-grade Bash scripts for automating, backing up, and managing an Unraid homelab environment.

## 📌 Overview

These scripts serve as a centralized toolkit for various Unraid maintenance and administration tasks. Broadly, the repository includes solutions for:

* Automated local and remote backups via ZFS replication and Rsync.
* Dynamic DNS updates for Cloudflare and deSEC.io.
* Configuration synchronization and safe-reloading for Docker containers like Authelia and Nginx Proxy Manager.
* Hardware telemetry extraction for Home Assistant.
* System maintenance, including automated log cleanup and custom USB HDD spin-down logic.

**Important:** Each individual file contains its own specific description, configurable variables, and detailed usage instructions directly inside its header block. Please refer to the specific script for exact details on what it does and how to configure it.

## 🚀 How to Use

These scripts are designed to be run via the **Unraid User Scripts plugin**. They utilize a dynamic execution architecture: the code you paste into Unraid is a lightweight wrapper that pulls the latest script logic directly from this repository into memory (`/dev/shm`) before execution. This ensures your server always runs the latest version without requiring manual updates in the Unraid GUI.

1. Install the **User Scripts** plugin from the Unraid Community Applications (CA) store.
2. Go to **Settings > User Scripts** and click **Add New Script**, giving it an appropriate name.
3. Open the specific script file you want to use from this GitHub repository.
4. Locate the commented `HOW TO USE` section at the top of the file.
5. Copy the wrapper code block provided in that header and paste it into your Unraid script editor.
6. Adjust the configuration variables (such as paths, API keys, or domain names) within that pasted wrapper to match your environment.
7. Set a schedule (e.g., Daily, Hourly, or Custom Cron) and apply your settings.
