#!/bin/bash

CONFIG_FILE="$HOME/.ssh/config"
JUNK_DIR="$HOME/.ssh/junk"
DATE_PREFIX=$(date +%Y-%m-%d)

# Ensure junk dir exists
mkdir -p "$JUNK_DIR"

# Backup current config
if [ -f "$CONFIG_FILE" ]; then
  BACKUP_FILE="$JUNK_DIR/${DATE_PREFIX}-config"
  echo "Backing up existing SSH config to $BACKUP_FILE"
  cp "$CONFIG_FILE" "$BACKUP_FILE"
else
  echo "No existing SSH config found, creating new one."
  touch "$CONFIG_FILE"
fi

# Ask user for repo alias
read -rp "Enter GitHub repo alias (e.g. cancermyarse, ergsy28, number84): " REPO_ALIAS

# Normalize alias (replace spaces with dashes, lowercase)
HOST_ALIAS="github-${REPO_ALIAS// /-}"
HOST_ALIAS=$(echo "$HOST_ALIAS" | tr '[:upper:]' '[:lower:]')

# Ask user for SSH key filename
read -rp "Enter SSH key filename (must exist in ~/.ssh/, e.g. ergsy28martok): " KEY_FILE

# Validate key file
if [ ! -f "$HOME/.ssh/$KEY_FILE" ]; then
  echo "ERROR: SSH key file $HOME/.ssh/$KEY_FILE does not exist!"
  exit 1
fi

# Append new host entry if not already present
if grep -q "Host $HOST_ALIAS" "$CONFIG_FILE"; then
  echo "⚠️ Host $HOST_ALIAS already exists in $CONFIG_FILE, skipping append."
else
  cat >> "$CONFIG_FILE" <<EOF

# GitHub project: $REPO_ALIAS
Host $HOST_ALIAS
    HostName github.com
    User git
    IdentityFile $HOME/.ssh/$KEY_FILE
    IdentitiesOnly yes
EOF
  echo "✅ Added new SSH config for $REPO_ALIAS using key $KEY_FILE"
fi

# Secure permissions
chmod 600 "$CONFIG_FILE"
chmod 700 "$HOME/.ssh"

# Check if we're inside a Git repo
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "📂 Detected Git repository in $(pwd)"
  read -rp "Do you want to configure the 'origin' remote for $HOST_ALIAS? (y/n): " CONFIGURE_REMOTE

  if [[ "$CONFIGURE_REMOTE" =~ ^[Yy]$ ]]; then
    if git remote get-url origin >/dev/null 2>&1; then
      # Extract current repo path from origin URL
      CURRENT_URL=$(git remote get-url origin)
      REPO_PATH=$(echo "$CURRENT_URL" | sed -E 's/.*[:\/](Powdermonkey1850\/[^ ]+)(\.git)?$/\1/')

      if [ -n "$REPO_PATH" ]; then
        NEW_URL="git@${HOST_ALIAS}:${REPO_PATH}.git"
        git remote set-url origin "$NEW_URL"
        echo "✅ Updated 'origin' to $NEW_URL"
      else
        echo "⚠️ Could not detect repo path from $CURRENT_URL"
      fi
    else
      # No origin exists → add one
      NEW_URL="git@${HOST_ALIAS}:Powdermonkey1850/${REPO_ALIAS}.git"
      git remote add origin "$NEW_URL"
      echo "✅ Added new 'origin' remote: $NEW_URL"
    fi
  fi
else
  echo "ℹ️ Not inside a Git repo, skipping remote configuration."
fi

