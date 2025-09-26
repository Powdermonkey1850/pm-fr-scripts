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
if grep -qE "^[[:space:]]*Host[[:space:]]+$HOST_ALIAS\$" "$CONFIG_FILE"; then
  echo "  Host $HOST_ALIAS already exists in $CONFIG_FILE, skipping append."
else
  cat >> "$CONFIG_FILE" <<EOF

# GitHub project: $REPO_ALIAS
# git clone git@${HOST_ALIAS}:powdermonkey1850/${REPO_ALIAS}.git
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

# Print helpful usage info
echo
echo "👉 To point a repo to this config, run:"
echo "git remote set-url origin git@${HOST_ALIAS}:powdermonkey1850/${REPO_ALIAS}.git"
echo

