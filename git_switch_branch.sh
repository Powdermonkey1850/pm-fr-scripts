#!/usr/bin/env bash
#
# /home/ubuntu/scripts/git_switch_branch.sh
# Safely switch git branches on production repositories.

set -euo pipefail

# --- ARG CHECK ---
if [[ $# -ne 1 ]]; then
  echo "❌ Usage: git_switch_branch.sh <branch-name>"
  exit 1
fi

BRANCH="$1"

# --- FIND GIT ROOT ---
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)

if [[ -z "$REPO_ROOT" ]]; then
  echo "❌ Not inside a Git repository - aborted at $(date)"
  exit 1
fi

echo "🔍 Git repository root: $REPO_ROOT"
echo "🌿 Target branch: $BRANCH"

# --- GUARANTEE OWNERSHIP RESTORATION ---
restore_ownership() {
  echo "🔁 Restoring ownership to www-data..."
  sudo chown -R www-data:www-data "$REPO_ROOT"
}
trap restore_ownership EXIT

# --- CHANGE OWNERSHIP TO UBUNTU ---
echo "🧩 Changing ownership to ubuntu..."
sudo chown -R ubuntu:ubuntu "$REPO_ROOT"

cd "$REPO_ROOT"

# --- VERIFY BRANCH EXISTS ---
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "✔ Local branch exists."
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  echo "✔ Remote branch exists. Creating local tracking branch..."
  git branch --track "$BRANCH" "origin/$BRANCH"
else
  echo "❌ Branch '$BRANCH' does not exist locally or on origin."
  exit 1
fi

# --- SWITCH BRANCH ---
echo "🔀 Switching to branch '$BRANCH'..."
git switch "$BRANCH"

echo "✅ Successfully switched to branch '$BRANCH'."
exit 0

