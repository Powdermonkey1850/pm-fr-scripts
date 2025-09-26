#!/bin/bash
set -euo pipefail

TMPFILE=$(mktemp)
DATE=$(date)

NOT_GIT=""
DIRTY=""
CLEAN=""

for dir in /var/www/prod-*; do
    SITENAME=$(basename "$dir")
    echo "🔎 Checking $SITENAME ..."

    if [ -d "$dir/.git" ]; then
        cd "$dir" || continue

        REMOTE=$(git config --get remote.origin.url 2>/dev/null || echo "No remote")
        BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "Unknown")

        if [[ "$REMOTE" == *"github.com"* ]]; then
            SERVICE="GitHub"
        elif [[ "$REMOTE" == *"codecommit::"* ]]; then
            SERVICE="AWS CodeCommit"
        else
            SERVICE="Unknown"
        fi

        if git diff-index --quiet HEAD -- 2>/dev/null; then
            CLEAN+="$SITENAME | $SERVICE | branch $BRANCH | CLEAN\n"
            echo "✅ $SITENAME is CLEAN."
        else
            DIRTY+="$SITENAME | $SERVICE | branch $BRANCH | DIRTY\n"
            echo "⚠️ $SITENAME is DIRTY."
        fi
    else
        NOT_GIT+="$SITENAME | Not a Git repo\n"
        echo "ℹ️ $SITENAME is not a Git repo."
    fi
done

{
    echo "Git Repository Status Report - $DATE"
    echo ""
    echo "=== Not a Git Repo ==="
    echo -e "${NOT_GIT:-None}"
    echo ""
    echo "=== Dirty Repos (uncommitted changes) ==="
    echo -e "${DIRTY:-None}"
    echo ""
    echo "=== Clean Repos ==="
    echo -e "${CLEAN:-None}"
} > "$TMPFILE"

echo "📧 Sending SES report..."
/home/ubuntu/scripts/send-ses.sh "📊 Git Repo Status Report" "patrick@powdermonkey.eu" "$TMPFILE"
echo "✅ Report sent."

rm -f "$TMPFILE"

