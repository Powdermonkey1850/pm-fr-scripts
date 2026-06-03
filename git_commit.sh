#!/bin/bash
# Harden /var/www Drupal sites only
# Ensures www-data:www-data ownership and secure permissions
# Ignores "junk" folder
# Restores executable permission for Drush when a Drupal site is detected

BASE_DIR="/var/www"
OWNER="www-data"
GROUP="www-data"

is_drupal_site() {
  SITE_PATH="$1"

  if [ -f "$SITE_PATH/web/core/lib/Drupal.php" ]; then
    return 0
  fi

  if [ -f "$SITE_PATH/core/lib/Drupal.php" ]; then
    return 0
  fi

  return 1
}

harden_site() {
  SITE_PATH="$1"
  BASENAME=$(basename "$SITE_PATH")

  if [ "$BASENAME" = "junk" ]; then
    echo "⏭️  Skipping junk folder: $SITE_PATH"
    return
  fi

  if ! is_drupal_site "$SITE_PATH"; then
    echo "⏭️  Skipping non-Drupal folder: $SITE_PATH"
    return
  fi

  echo "🔧 Hardening Drupal site: $SITE_PATH ..."
  sudo chown -R "$OWNER:$GROUP" "$SITE_PATH"

  # Files = 644
  sudo find "$SITE_PATH" -type f -exec chmod 644 {} \;

  # Directories = 755
  sudo find "$SITE_PATH" -type d -exec chmod 755 {} \;

  # Drush executable from project root
  if [ -f "$SITE_PATH/vendor/drush/drush/drush" ]; then
    sudo chmod +x "$SITE_PATH/vendor/drush/drush/drush"
    echo "✅ Drush executable fixed: $SITE_PATH/vendor/drush/drush/drush"
  else
    echo "⚠️  Drush executable not found: $SITE_PATH/vendor/drush/drush/drush"
  fi

  # Drush PHP target also needs to be executable for this install style
  if [ -f "$SITE_PATH/vendor/drush/drush/drush.php" ]; then
    sudo chmod +x "$SITE_PATH/vendor/drush/drush/drush.php"
    echo "✅ Drush PHP target fixed: $SITE_PATH/vendor/drush/drush/drush.php"
  fi

  echo "✅ Hardened $SITE_PATH"
}

if [ "$1" = "--cron" ]; then
  echo "📅 Running in cron mode: hardening ALL Drupal sites in $BASE_DIR excluding junk"

  for SITE in "$BASE_DIR"/*; do
    [ -d "$SITE" ] && harden_site "$SITE"
  done

  exit 0
fi

echo "📂 Drupal sites found in $BASE_DIR excluding junk:"
SITES=()
i=1

for SITE in "$BASE_DIR"/*; do
  if [ -d "$SITE" ] && [ "$(basename "$SITE")" != "junk" ] && is_drupal_site "$SITE"; then
    echo "  [$i] $(basename "$SITE")"
    SITES+=("$SITE")
    ((i++))
  fi
done

if [ ${#SITES[@]} -eq 0 ]; then
  echo "❌ No Drupal sites found in $BASE_DIR"
  exit 1
fi

echo "  [A] All Drupal sites"
read -rp "Select site number to harden or 'A' for all: " CHOICE

if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
  INDEX=$((CHOICE-1))

  if [ "$INDEX" -ge 0 ] && [ "$INDEX" -lt "${#SITES[@]}" ]; then
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
