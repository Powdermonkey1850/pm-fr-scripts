#!/bin/bash
# Harden /var/www sites
# Ensures www-data:www-data ownership and secure permissions
# Ignores "junk" folder

BASE_DIR="/var/www"
OWNER="www-data"
GROUP="www-data"

# Harden function
harden_site() {
  SITE_PATH="$1"
  BASENAME=$(basename "$SITE_PATH")

  # Skip junk folder
  if [ "$BASENAME" = "junk" ]; then
    echo "⏭️  Skipping junk folder: $SITE_PATH"
    return
  fi

  echo "🔧 Hardening $SITE_PATH ..."
  sudo chown -R $OWNER:$GROUP "$SITE_PATH"

  # Files = 644 (rw for owner, r for group+others)
  find "$SITE_PATH" -type f -exec chmod 644 {} \;

  # Directories = 755 (rwx for owner, rx for group+others)
  find "$SITE_PATH" -type d -exec chmod 755 {} \;

  # Drush (if exists) must be executable
  if [ -f "$SITE_PATH/vendor/drush/drush/drush" ]; then
    chmod +x "$SITE_PATH/vendor/drush/drush/drush"
  fi

  echo "✅ Hardened $SITE_PATH"
}

# Detect if running in cron mode (non-interactive)
if [ "$1" == "--cron" ]; then
  echo "📅 Running in cron mode: hardening ALL sites in $BASE_DIR (excluding junk)"
  for SITE in "$BASE_DIR"/*; do
    [ -d "$SITE" ] && harden_site "$SITE"
  done
  exit 0
fi

# Interactive mode
echo "📂 Sites found in $BASE_DIR (excluding junk):"
SITES=()
i=1
for SITE in "$BASE_DIR"/*; do
  if [ -d "$SITE" ] && [ "$(basename "$SITE")" != "junk" ]; then
    echo "  [$i] $(basename "$SITE")"
    SITES+=("$SITE")
    ((i++))
  fi
done

echo "  [A] All sites"
read -rp "Select site number to harden (or 'A' for all): " CHOICE

if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
  INDEX=$((CHOICE-1))
  if [ $INDEX -ge 0 ] && [ $INDEX -lt ${#SITES[@]} ]; then
    harden_site "${SITES[$INDEX]}"
  else
    echo "❌ Invalid selection"
    exit 1
  fi
elif [[ "$CHOICE" =~ ^[Aa]$ ]]; then
  for SITE in "${SITES[@]}"; do
    harden_site "$SITE"
  done
else
  echo "❌ Invalid input"
  exit 1
fi

