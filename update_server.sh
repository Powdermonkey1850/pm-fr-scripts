#!/bin/bash
# /home/ubuntu/scripts/update_server.sh

LOGFILE="/home/ubuntu/tmp/update_server.log"
EMAIL="patrick@powdermonkey.eu"

# Ensure tmp dir exists
mkdir -p /home/ubuntu/tmp

{
  echo "=== 🚀 Server Update Started at $(date) ==="
  echo

  # Step 1: Update package list
  echo ">>> Running apt update..."
  sudo apt update
  echo

  # Step 2: Upgrade packages
  echo ">>> Running apt upgrade..."
  sudo apt upgrade -y
  echo

  # Step 3: Dist-upgrade (kernel/security)
  echo ">>> Running apt dist-upgrade..."
  sudo apt dist-upgrade -y
  echo

  # Step 4: Autoremove old packages
  echo ">>> Running apt autoremove..."
  sudo apt autoremove -y
  echo

  # Step 5: Check if reboot required
  if [ -f /var/run/reboot-required ]; then
    echo "⚠️ Reboot required after updates."
  else
    echo "✅ No reboot required."
  fi

  echo
  echo "=== ✅ Update Finished at $(date) ==="

} &> "$LOGFILE"

# Send email report
/home/ubuntu/scripts/send-ses.sh "📦 Server Update Report" "$EMAIL" "$LOGFILE"

# Cleanup
rm -f "$LOGFILE"

