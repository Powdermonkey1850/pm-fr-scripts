#!/usr/bin/env bash
set -euo pipefail

NACL_ID="acl-0c4405bd5c0ac28dd"
AWS_CLI="$(command -v aws)"

echo "Fetching existing entries for cleanup..."

# Get all rule numbers for this NACL
RULES=$($AWS_CLI ec2 describe-network-acls \
  --network-acl-ids "$NACL_ID" \
  --query "NetworkAcls[0].Entries[].{Num:RuleNumber,Egress:Egress}" \
  --output json)

echo "Found rules:"
echo "$RULES"

# Extract rule numbers equal or larger than 1000 and lower than 30000
for entry in $(echo "$RULES" | jq -c '.[]'); do
    RULE_NUM=$(echo "$entry" | jq -r '.Num')
    EGRESS=$(echo "$entry" | jq -r '.Egress')

    # Only clean rules created by our blocking script
    if (( RULE_NUM >= 1000 && RULE_NUM <= 30000 )); then
        echo "Deleting rule: $RULE_NUM (egress=$EGRESS)"

        if [ "$EGRESS" = "true" ]; then
            $AWS_CLI ec2 delete-network-acl-entry \
              --network-acl-id "$NACL_ID" \
              --egress \
              --rule-number "$RULE_NUM"
        else
            $AWS_CLI ec2 delete-network-acl-entry \
              --network-acl-id "$NACL_ID" \
              --ingress \
              --rule-number "$RULE_NUM"
        fi
    fi
done

echo "Cleanup completed."

