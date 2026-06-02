#!/usr/bin/env bash
#
# /home/ubuntu/scripts/git_add_commit_push.sh
# Temporarily switch repo ownership to ubuntu for Git SSH access,
# then restore ownership to www-data.
#
# Martok assumptions:
# - Site folders are in /var/www/prod-*
# - Site folders normally owned by www-data
# - ubuntu has GitHub SSH config/keys
# - ownership is restored to www-data on exit

set -euo pipefail

EMAIL_TO="patrick@powdermonkey.eu"
SEND_SES="/home/ubuntu/scripts/send-ses.sh"
RUN_USER="ubuntu"
RESTORE_USER="www-data"
RESTORE_GROUP="www-data"

# --- BASIC CHECKS ---

if [[ ! -x "$SEND_SES" ]]; then
  echo "❌ SES send script not found or not executable: $SEND_SES"
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "❌ git command not found."
  exit 1
fi

# --- FIND GIT ROOT ---
# First try as ubuntu/current user.
# This may work if ownership has already been adjusted or Git safe.directory is configured.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)

# Fallback: try as www-data because prod folders are normally owned by www-data.
if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT=$(sudo -u "$RESTORE_USER" git rev-parse --show-toplevel 2>/dev/null || true)
fi

if [[ -z "$REPO_ROOT" ]]; then
  echo "❌ Not inside a Git repository - aborted at $(date)"
  echo "Current directory: $(pwd)"
  exit 1
fi

case "$REPO_ROOT" in
  /var/www/prod-*)
    ;;
  *)
    echo "❌ Refusing to run outside /var/www/prod-*"
    echo "Repo root was: $REPO_ROOT"
    exit 1
    ;;
esac

echo "🔍 Git repository root: $REPO_ROOT"

# --- GUARANTEE OWNERSHIP RESTORATION ---

restore_ownership() {
  echo "🔁 Restoring ownership to ${RESTORE_USER}:${RESTORE_GROUP}..."
  sudo chown -R "$RESTORE_USER:$RESTORE_GROUP" "$REPO_ROOT"
}

trap restore_ownership EXIT

# --- TEMPORARILY CHANGE OWNERSHIP TO UBUNTU ---

echo "🧩 Temporarily changing ownership to ${RUN_USER}:${RUN_USER}..."
sudo chown -R "$RUN_USER:$RUN_USER" "$REPO_ROOT"

cd "$REPO_ROOT"

# --- CONFIRM GIT ACCESS AS UBUNTU ---

if ! git status --short >/dev/null 2>&1; then
  echo "❌ Cannot run git status as $RUN_USER in $REPO_ROOT"
  exit 1
fi

# --- COMMIT MESSAGE ---

DEFAULT_MESSAGE="ups from live"

read -r -p "Optional commit message addition, or press Enter for none: " USER_MESSAGE

if [[ -n "$USER_MESSAGE" ]]; then
  COMMIT_MESSAGE="$DEFAULT_MESSAGE - $USER_MESSAGE"
else
  COMMIT_MESSAGE="$DEFAULT_MESSAGE"
fi

echo "📝 Commit message: $COMMIT_MESSAGE"

# --- CURRENT BRANCH / UPSTREAM ---

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [[ "$CURRENT_BRANCH" == "HEAD" ]]; then
  echo "❌ Repository is in detached HEAD state."
  echo "Aborting to avoid committing or pushing from detached HEAD."
  exit 1
fi

UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)

if [[ -z "$UPSTREAM" ]]; then
  echo "❌ Current branch '$CURRENT_BRANCH' has no upstream branch set."
  echo
  echo "Set it manually with:"
  echo "cd $REPO_ROOT"
  echo "git push -u origin $CURRENT_BRANCH"
  exit 1
fi

echo "🌿 Current branch: $CURRENT_BRANCH"
echo "🔗 Upstream branch: $UPSTREAM"

# --- CHECK LOCAL CHANGES ---

echo "🔍 Checking local working tree..."

if git diff --quiet && git diff --cached --quiet; then
  HAS_LOCAL_CHANGES="no"
  echo "✅ No local working-tree changes currently detected."
else
  HAS_LOCAL_CHANGES="yes"
  echo "ℹ️ Local working-tree changes detected."
  echo "They will be committed after the remote branch safety check."
fi

# --- FETCH AND COMPARE WITH UPSTREAM BEFORE COMMITTING ---

echo "🔄 Fetching latest remote state..."
git fetch --prune

LOCAL_COMMIT=$(git rev-parse @)
REMOTE_COMMIT=$(git rev-parse "@{u}")
BASE_COMMIT=$(git merge-base @ "@{u}")

if [[ "$LOCAL_COMMIT" == "$REMOTE_COMMIT" ]]; then
  echo "✅ Local branch is up to date with $UPSTREAM."

elif [[ "$LOCAL_COMMIT" == "$BASE_COMMIT" ]]; then
  echo "⬇️ Local branch is behind $UPSTREAM."
  echo
  echo "Recommended action: rebase before committing and pushing."
  echo "This avoids unnecessary merge commits and reduces the risk of divergent branches."
  echo
  read -r -p "Run git pull --rebase now? [y/N]: " REBASE_CHOICE

  if [[ "$REBASE_CHOICE" =~ ^[Yy]$ ]]; then
    echo "🔁 Running git pull --rebase..."
    git pull --rebase
  else
    echo "❌ Aborted to avoid working from an out-of-date branch."
    exit 1
  fi

elif [[ "$REMOTE_COMMIT" == "$BASE_COMMIT" ]]; then
  echo "⬆️ Local branch is ahead of $UPSTREAM."
  echo "✅ Safe to continue."

else
  echo "⚠️ Local and remote branches have diverged."
  echo
  echo "This means both local and remote have commits the other does not have."
  echo "Best choice in most cases: rebase local commits on top of remote changes."
  echo
  echo "1) Run git pull --rebase"
  echo "2) Abort and inspect manually"
  echo
  read -r -p "Choose [1/2]: " DIVERGENCE_CHOICE

  case "$DIVERGENCE_CHOICE" in
    1)
      echo "🔁 Running git pull --rebase..."
      git pull --rebase
      ;;
    2|*)
      echo "❌ Aborted. Manual review recommended:"
      echo
      echo "cd $REPO_ROOT"
      echo "git status"
      echo "git log --oneline --graph --decorate --all -30"
      echo "git pull --rebase"
      exit 1
      ;;
  esac
fi

# --- REFRESH BRANCH DATA AFTER POSSIBLE REBASE ---

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}")

# --- GIT ADD ---

echo "➕ Running git add . ..."
git add .

# --- GIT COMMIT ---

if git diff --cached --quiet; then
  echo "✅ No staged changes to commit."
  DID_COMMIT="no"
else
  echo "📦 Running git commit..."
  git commit -m "$COMMIT_MESSAGE"
  DID_COMMIT="yes"
fi

# --- FINAL REMOTE CHECK BEFORE PUSH ---

echo "🔄 Final remote check before push..."
git fetch --prune

LOCAL_COMMIT=$(git rev-parse @)
REMOTE_COMMIT=$(git rev-parse "@{u}")
BASE_COMMIT=$(git merge-base @ "@{u}")

if [[ "$LOCAL_COMMIT" == "$REMOTE_COMMIT" ]]; then
  echo "✅ Local and remote are already identical. Nothing to push."

  "$SEND_SES" "✅ Git OK - Nothing To Push" "$EMAIL_TO" "Repo: $REPO_ROOT
Branch: $CURRENT_BRANCH
Upstream: $UPSTREAM
Commit created: $DID_COMMIT
Local changes before run: $HAS_LOCAL_CHANGES
Finished at: $(date)"

  exit 0

elif [[ "$REMOTE_COMMIT" == "$BASE_COMMIT" ]]; then
  echo "✅ Local branch is ahead of remote. Safe to push."

else
  echo "❌ Remote changed again or branch diverged before push."
  echo "Aborting to avoid creating divergent branches."
  echo
  echo "Manual review recommended:"
  echo
  echo "cd $REPO_ROOT"
  echo "git status"
  echo "git log --oneline --graph --decorate --all -30"
  echo "git pull --rebase"
  exit 1
fi

# --- GIT PUSH ---

echo "🚀 Running git push..."
git push

echo "✅ Git add, commit, and push completed successfully."

"$SEND_SES" "✅ Git Push OK" "$EMAIL_TO" "Repo: $REPO_ROOT
Branch: $CURRENT_BRANCH
Upstream: $UPSTREAM
Commit message: $COMMIT_MESSAGE
Commit created: $DID_COMMIT
Local changes before run: $HAS_LOCAL_CHANGES
Finished at: $(date)"

exit 0
