#!/bin/bash
set -euo pipefail

TMPFILE=$(mktemp)
DATE=$(date)

NOT_GIT=""
DIRTY_AWS=""
DIRTY_GH=""
DIRTY_OTHER=""
CLEAN_AWS=""
CLEAN_GH=""
CLEAN_OTHER=""

for dir in /var/www/prod-*; do
    SITENAME=$(basename "$dir")
    echo "🔎 Checking $SITENAME ..."

    if [ -d "$dir/.git" ]; then
        cd "$dir" || continue

        REMOTE=$(git config --get remote.origin.url 2>/dev/null || echo "No remote")

        # Branch detection (with detached HEAD handling)
        if git symbolic-ref --quiet HEAD > /dev/null 2>&1; then
            BRANCH=$(git rev-parse --abbrev-ref HEAD)
            WARNING=""
        else
            BRANCH="DETACHED"
            WARNING="⚠️ Detached HEAD"
        fi

        # Detect service
        if [[ "$REMOTE" == *"git-codecommit."*".amazonaws.com"* ]]; then
            SERVICE="AWS CodeCommit"
        elif [[ "$REMOTE" == git@github-*:* ]]; then
            SERVICE="GitHub"
        else
            SERVICE="Unknown"
        fi

        # Check repo status safely

if git rev-parse --verify HEAD >/dev/null 2>&1; then
    if git diff --quiet && git diff --cached --quiet; then
        STATUS="CLEAN"
    else
        STATUS="DIRTY"
    fi
else
    STATUS="⚠️ No commits"
fi



# Sort into buckets
        case "$STATUS" in
            "CLEAN")
                case "$SERVICE" in
                    "AWS CodeCommit") CLEAN_AWS+="$SITENAME | $SERVICE | branch $BRANCH | CLEAN $WARNING\n" ;;
                    "GitHub") CLEAN_GH+="$SITENAME | $SERVICE | branch $BRANCH | CLEAN $WARNING\n" ;;
                    *) CLEAN_OTHER+="$SITENAME | $SERVICE | branch $BRANCH | CLEAN $WARNING\n" ;;
                esac
                echo "✅ $SITENAME is CLEAN. $WARNING"
                ;;
            "DIRTY")
                case "$SERVICE" in
                    "AWS CodeCommit") DIRTY_AWS+="$SITENAME | $SERVICE | branch $BRANCH | DIRTY $WARNING\n" ;;
                    "GitHub") DIRTY_GH+="$SITENAME | $SERVICE | branch $BRANCH | DIRTY $WARNING\n" ;;
                    *) DIRTY_OTHER+="$SITENAME | $SERVICE | branch $BRANCH | DIRTY $WARNING\n" ;;
                esac
                echo "  $SITENAME is DIRTY. $WARNING"
                ;;
            "⚠️ No commits")
                DIRTY_OTHER+="$SITENAME | $SERVICE | branch $BRANCH | ⚠️ No commits\n"
                echo "  ⚠️ $SITENAME has no commits yet!"
                ;;
        esac
    else
        NOT_GIT+="$SITENAME | Not a Git repo\n"
        echo "  $SITENAME is not a Git repo."
    fi
done

{
    echo "Git Repository Status Report - $DATE"
    echo ""

    echo "=== Not a Git Repo ==="
    echo -e "${NOT_GIT:-None}"
    echo ""

    echo "=== Dirty Repos - AWS CodeCommit ==="
    echo -e "${DIRTY_AWS:-None}"
    echo ""

    echo "=== Dirty Repos - GitHub ==="
    echo -e "${DIRTY_GH:-None}"
    echo ""

    echo "=== Dirty Repos - Other/Unknown ==="
    echo -e "${DIRTY_OTHER:-None}"
    echo ""

    echo "=== Clean Repos - AWS CodeCommit ==="
    echo -e "${CLEAN_AWS:-None}"
    echo ""

    echo "=== Clean Repos - GitHub ==="
    echo -e "${CLEAN_GH:-None}"
    echo ""

    echo "=== Clean Repos - Other/Unknown ==="
    echo -e "${CLEAN_OTHER:-None}"
    echo ""
} > "$TMPFILE"

echo "📧 Sending SES report..."
/home/ubuntu/scripts/send-ses.sh "📊 Git Repo Status Report" "patrick@powdermonkey.eu" "$TMPFILE"
echo "✅ Report sent."

rm -f "$TMPFILE"

