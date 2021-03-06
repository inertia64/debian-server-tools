#!/bin/bash
#
# Create, list and update AWS Route53 DNS resource record sets.
#
# VERSION       :0.2.1
# DOCS          :http://jmespath.org/examples.html
# DEPENDS       :pip3 install awscli
# LOCATION      :/usr/local/bin/aws-route53-rrs.sh

# Usage
# Configure
#     aws configure
# List all zones
#     aws-route53-rrs.sh . .
# Add HOSTED_ZONE_ID=ZONE-ID to your ~/.profile
#     aws-route53-rrs.sh . TXT
#     aws-route53-rrs.sh non-existent-to-create.example.com. AAAA
#     aws-route53-rrs.sh example.com. A
#     aws-route53-rrs.sh example.com. IN TXT
# Delete a record by appending DELETE! in the Value field

HOSTED_ZONE="$HOSTED_ZONE_ID"

Route53_list_rrs()
{
    aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE" "$@"
}

Route53_change_rrs()
{
    local TEMP_JSON="$1"

    aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE" \
        --change-batch "file://${TEMP_JSON}"
}

Validate_request()
{
    test -s "$TEMP_JSON"
    python <<EOF
import sys, json
j = open('${TEMP_JSON}').read()
try:
    json.loads(j)
except ValueError:
    sys.exit(20)
EOF
}

Usage()
{
    cat <<EOF
Usage: $0 name. TYPE
Update RRs by editing JSON data.
EOF
    exit 0
}

set -e

# Credentials
if [ ! -r "${HOME}/.aws/credentials" ]; then
    echo "Unconfigured ~/.aws/credentials" 1>&2
    exit 125
fi

NAME="$1"
# Support bind format
if [ "$2" == IN ]; then
    shift
fi
TYPE="$2"

# List all zones
if [ "$NAME" == . ] && [ "$TYPE" == . ]; then
    aws route53 list-hosted-zones | jq -r '.HostedZones[] | .Name + " " + .Id'
    exit 0
fi

# Get name. and TYPE
if [ "$#" != 2 ] || [ "${NAME:(-1)}" != . ] || [ -n "${TYPE//[A-Z]/}" ]; then
    Usage
fi

# Check HOSTED_ZONE_ID
if [ -z "$HOSTED_ZONE" ]; then
    echo "Unset HOSTED_ZONE_ID" 1>&2
    exit 125
fi

# List names and values of RRs
if [ "$NAME" == . ]; then
    Route53_list_rrs --output text \
        --query "ResourceRecordSets[?Type == '${TYPE}'].[Name, ResourceRecords[0].Value]"
    exit 0
fi

# Temporary file to edit JSON data
TEMP_JSON="$(mktemp)"
trap 'rm -f "$TEMP_JSON"' EXIT HUP INT QUIT PIPE TERM

# Get RRs
Route53_list_rrs \
    --query "ResourceRecordSets[?Name == '${NAME}'] | [?Type == '${TYPE}'] | [0]" \
    > "$TEMP_JSON"
MX_PRIO=""

# Operate based on RRs
if [ "$(cat "$TEMP_JSON")" == null ]; then
    # New RRs
    if [ "$TYPE" == MX ]; then
        printf -v MX_PRIO '10 '
    fi
    printf '{\n "Name": "%s",\n "Type": "%s",\n "ResourceRecords": [\n  { "Value": "%s" }\n ],\n "TTL": 86400\n}\n' \
        "$NAME" "$TYPE" "$MX_PRIO" \
        > "$TEMP_JSON"
    editor "$TEMP_JSON"
    Validate_request
    # Build the request
    # @FIXME The same file is input and output at the same time
    printf '{ "Changes": [ { "Action": "UPSERT", "ResourceRecordSet": %s } ] }' \
        "$(cat "$TEMP_JSON")" \
        > "$TEMP_JSON"
    # Create RRs
    RESPONSE="$(Route53_change_rrs "$TEMP_JSON")"
else
    # Change RRs
    editor "$TEMP_JSON"
    Validate_request
    if jq '.ResourceRecords[0].Value' < "$TEMP_JSON" | grep -q 'DELETE!'; then
        # Build the request
        printf '{ "Changes": [ { "Action": "DELETE", "ResourceRecordSet": %s } ] }' \
            "$(sed -e '/"Value":/s#DELETE!##' "$TEMP_JSON")" \
            > "$TEMP_JSON"
        # Delete RRs
        RESPONSE="$(Route53_change_rrs "$TEMP_JSON")"
    else
        # Build the request
        printf '{ "Changes": [ { "Action": "UPSERT", "ResourceRecordSet": %s } ] }' \
            "$(cat "$TEMP_JSON")" \
            > "$TEMP_JSON"
        # Update RRs
        RESPONSE="$(Route53_change_rrs "$TEMP_JSON")"
    fi
fi

# Check response
grep -q '"ChangeInfo": {' <<< "$RESPONSE"
grep -q '"Status": "PENDING"' <<< "$RESPONSE"
echo "OK."
