#!/bin/bash
set -euo pipefail

REPORT="Git Repository Status Report - $(date)\n\n"

# Iterate over all prod-* folders
for dir in /var/www/prod-*; do
    if [ -d "$dir/.git" ]; then
        cd "$dir"

        SITE_NAME=$(basename "$dir")
        REMOTE_URL=$(git config --get remote.origin.url || echo "No remote")
        BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "Unknown branch")

        # Determine service
        if [[ "$REMOTE_URL" == *"github.com"* ]]; then
            SERVICE="GitHub"
        elif [[ "$REMOTE_URL" == *"codecommit::"* ]]; then
            SERVICE="AWS CodeCommit"
        else
            SERVICE="Unknown"
        fi

        # Get status summary (short form, no untracked detail)
        STATUS=$(git status --short || echo "Unable to get status")

        REPORT+="Site: $SITE_NAME\n"
        REPORT+="Service: $SERVICE\n"
        REPORT+="Branch: $BRANCH\n"
        REPORT+="Remote: $REMOTE_URL\n"
        REPORT+="Status:\n$STATUS\n\n"
    else
        REPORT+="Site: $(basename "$dir") has no .git repo\n\n"
    fi
done

# Send report via SES helper script
/home/ubuntu/scripts/send-ses.sh "📊 Git Status Report" "$REPORT" "patrick@powdermonkey.eu"

