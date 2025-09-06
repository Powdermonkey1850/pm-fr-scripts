#!/bin/bash

# Constants
SSH_DIR="/home/ubuntu/.ssh"
EMAIL="patrick@powdermonkey.eu"

# Prompt for key name
read -p "Enter SSH key name (e.g., id_ed25519_custom): " KEY_NAME

# Validate key name
if [[ -z "$KEY_NAME" ]]; then
  echo "❌ Key name is required. Exiting."
  exit 1
fi

KEY_PATH="$SSH_DIR/$KEY_NAME"

# Prompt for passphrase
read -p "Do you want to set a passphrase? [y/N]: " USE_PASSPHRASE
USE_PASSPHRASE=${USE_PASSPHRASE,,}  # to lowercase

# Create SSH directory if it doesn't exist
if [ ! -d "$SSH_DIR" ]; then
  echo "📁 Creating SSH directory: $SSH_DIR"
  mkdir -p "$SSH_DIR"
  chown ubuntu:ubuntu "$SSH_DIR"
  chmod 700 "$SSH_DIR"
fi

# Include key name in the comment
COMMENT="$EMAIL ($KEY_NAME)"

# Generate the SSH key
if [[ "$USE_PASSPHRASE" == "y" || "$USE_PASSPHRASE" == "yes" ]]; then
  echo "🔐 Generating SSH key with passphrase..."
  ssh-keygen -t ed25519 -C "$COMMENT" -f "$KEY_PATH"
else
  echo "🔐 Generating SSH key without passphrase..."
  ssh-keygen -t ed25519 -C "$COMMENT" -f "$KEY_PATH" -N ""
fi

# Set correct permissions
chown ubuntu:ubuntu "$KEY_PATH" "$KEY_PATH.pub"
chmod 600 "$KEY_PATH"
chmod 644 "$KEY_PATH.pub"

echo "✅ SSH key generated:"
echo "  Private: $KEY_PATH"
echo "  Public : $KEY_PATH.pub"

