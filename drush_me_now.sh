#!/usr/bin/env bash
# customdrush - Run Drush commands from the root of a Drupal Git repository.

set -e

# Check if we're inside a Git repository
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "❌ Error: Not inside a Git repository."
  exit 1
fi

# Find the Git repository root
GIT_ROOT=$(git rev-parse --show-toplevel)

# Check if this looks like a Drupal site
if [ ! -f "$GIT_ROOT/web/index.php" ] && [ ! -f "$GIT_ROOT/core/lib/Drupal.php" ]; then
  echo "❌ Error: This does not appear to be a Drupal project."
  echo "   Expected to find 'web/index.php' or 'core/lib/Drupal.php' in: $GIT_ROOT"
  exit 1
fi

# Build the Drush executable path
DRUSH_CMD="$GIT_ROOT/vendor/drush/drush/drush"

# Check if Drush exists
if [ ! -x "$DRUSH_CMD" ]; then
  echo "❌ Error: Drush not found at $DRUSH_CMD"
  echo "👉 Run 'composer require drush/drush' from your Drupal root to install it."
  exit 1
fi

# Ensure at least one argument is passed
if [ $# -eq 0 ]; then
  echo "Usage: customdrush <drush-command> [arguments]"
  exit 1
fi

# On-screen notification
echo "🚀 Executing Drush from:"
echo "   $DRUSH_CMD"
echo "-------------------------------------------"

# Move to the Git root and execute Drush
cd "$GIT_ROOT"
"$DRUSH_CMD" "$@"

