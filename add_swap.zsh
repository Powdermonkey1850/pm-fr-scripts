#!/usr/bin/env zsh
set -euo pipefail

SWAPFILE="/swapfile"
SIZE="${1:-4G}"

# Create swapfile if missing
if [[ ! -f "$SWAPFILE" ]]; then
  /usr/bin/sudo /usr/bin/fallocate -l "$SIZE" "$SWAPFILE"
  /usr/bin/sudo /usr/bin/chmod 600 "$SWAPFILE"
  /usr/bin/sudo /usr/sbin/mkswap "$SWAPFILE" >/dev/null
fi

# Enable swap (ignore if already enabled)
if ! /usr/sbin/swapon --show=NAME | /bin/grep -qx "$SWAPFILE"; then
  /usr/bin/sudo /usr/sbin/swapon "$SWAPFILE"
fi

# Persist in fstab (only add if missing)
if ! /bin/grep -qE "^[[:space:]]*${SWAPFILE}[[:space:]]" /etc/fstab; then
  echo "${SWAPFILE} none swap sw 0 0" | /usr/bin/sudo /usr/bin/tee -a /etc/fstab >/dev/null
fi

# Show result
/usr/sbin/swapon --show
/usr/bin/free -h

