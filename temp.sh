#!/bin/bash
# File: /home/ubuntu/scripts/git-backup-all.sh

BASE_DIR="/var/www"
COMMIT_MSG="gen bak martok"

for site in "$BASE_DIR"/prod-*; do
    if [ -d "$site/.git" ]; then
        echo ">>> Processing $site"

        # Run git commands as www-data
        sudo -u www-data git -C "$site" add .
        sudo -u www-data git -C "$site" commit -m "$COMMIT_MSG"
        sudo -u www-data git -C "$site" push

        echo ">>> Finished $site"
        echo "--------------------------------"
    else
        echo ">>> Skipping $site (no .git repo)"
    fi
done

