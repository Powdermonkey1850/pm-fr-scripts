#!/bin/bash
# Script to change ownership of /var/www/prod* to www-data:www-data

# Exit on any error
set -e

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi

# Get all prod* directories
dirs=(/var/www/prod*/)
if [ ${#dirs[@]} -eq 0 ]; then
  echo "No directories starting with 'prod' found in /var/www."
  exit 0
fi

echo "Available 'prod' directories:"
select dir in "${dirs[@]}" "All"; do
  case $dir in
    "All")
      echo "Changing ownership for all prod* directories..."
      chown -R www-data:www-data /var/www/prod*/
      echo "Ownership updated for all prod* directories."
      break
      ;;
    *)
      if [ -n "$dir" ]; then
        echo "Changing ownership for $dir..."
        chown -R www-data:www-data "$dir"
        echo "Ownership updated for $dir."
        break
      else
        echo "Invalid selection."
      fi
      ;;
  esac
done

