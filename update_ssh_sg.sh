#!/bin/bash
set -euo pipefail

# === Configuration ===
REGION="eu-west-2"
SG_ID="sg-063bb73f0a5e2109e"   # Replace with your powdermonkey-ssh-sg GroupId
PORT=22
AWS="aws"

# === Get current public IP ===
MY_IP=$(curl -s https://checkip.amazonaws.com)/32
if [ -z "$MY_IP" ]; then
  echo "❌ Could not detect public IP"
  exit 1
fi
echo "📡 Your current public IP is: $MY_IP"

# === Get existing SSH rules ===
EXISTING=$($AWS ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --region "$REGION" \
  --query "SecurityGroups[].IpPermissions[?FromPort==\`$PORT\` && ToPort==\`$PORT\` && IpProtocol=='tcp'].IpRanges[].CidrIp" \
  --output text)

if echo "$EXISTING" | grep -q "$MY_IP"; then
  echo "✅ SSH from $MY_IP already allowed in SG $SG_ID"
else
  echo "🔓 Adding SSH rule for $MY_IP..."
  $AWS ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port $PORT \
    --cidr "$MY_IP" \
    --region "$REGION"
  echo "✅ Added."
fi

# === Display summary of all SSH rules ===
echo "📜 Current SSH rules in $SG_ID:"
$AWS ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --region "$REGION" \
  --query "SecurityGroups[].IpPermissions[?FromPort==\`$PORT\` && ToPort==\`$PORT\` && IpProtocol=='tcp'].IpRanges[].CidrIp" \
  --output text

