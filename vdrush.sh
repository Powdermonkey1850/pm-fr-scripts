#!/usr/bin/env bash

DRUSH_PATH="./vendor/drush/drush/drush"

if [ ! -x "$DRUSH_PATH" ]; then
  echo "❌ Drush not found at $DRUSH_PATH"
  echo "👉 Are you in the Drupal project root?"
  exit 1
fi

exec "$DRUSH_PATH" "$@"

