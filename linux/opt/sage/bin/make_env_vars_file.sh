#! /bin/bash

# Creates a file which sets environment variables. These are common variables
# used by other init scripts that set up an AWS EC2 Linux instance.

# set -ex

usage() {
  msg="To run create_env_vars_file.sh, ensure that AWS_REGION, STACK_ID, "
  msg+="and STACK_NAME are set and not empty."
  echo "$msg"
}

if [[ -z "$AWS_REGION" || -z "$STACK_ID" || -z "$STACK_NAME" ]]; then
  usage >&2
  exit 1
fi

EC2_INSTANCE_ID=$(/usr/bin/curl -s http://169.254.169.254/latest/meta-data/instance-id)
ROOT_DISK_ID=$(/usr/bin/aws ec2 describe-volumes \
  --region "$AWS_REGION" \
  --filters Name=attachment.instance-id,Values="$EC2_INSTANCE_ID" \
  --query Volumes[].VolumeId --out text)
EC2_INSTANCE_TAGS=$(aws --region "$AWS_REGION" \
  ec2 describe-tags \
  --filters Name=resource-id,Values="$EC2_INSTANCE_ID")

extract_tag_value() {
  echo "$EC2_INSTANCE_TAGS" | jq -j --arg KEYNAME "$1" '.Tags[] | select(.Key == $KEYNAME).Value '
}

DEPARTMENT=$(extract_tag_value Department)
PROJECT=$(extract_tag_value Project)
PROVISIONING_PRINCIPAL_ARN=$(extract_tag_value 'aws:servicecatalog:provisioningPrincipalArn')
ACCESS_APPROVED_ROLEID=$(extract_tag_value AccessApprovedRoleId)
PRINCIPAL_ID=${PROVISIONING_PRINCIPAL_ARN##*/}  #Immutable Synapse userid derived from assume-role session name

if [[ "$PRINCIPAL_ID" =~ [[:digit:]] ]]; then
  USER_PROFILE_RESPONSE=$(curl -s "https://repo-prod.prod.sagebase.org/repo/v1/userProfile/$PRINCIPAL_ID")
  SYNAPSE_USERNAME=$(echo "$USER_PROFILE_RESPONSE" | jq -r '.userName')
  if [[ -z "$SYNAPSE_USERNAME" || "$SYNAPSE_USERNAME" == "null" ]]; then
    echo "Could not extract user name from Synapse user profile response: $USER_PROFILE_RESPONSE" >&2
    exit 1
  fi
  OWNER_EMAIL="$SYNAPSE_USERNAME@synapse.org"
elif [[ "$PRINCIPAL_ID" =~ .*"@".* ]]; then
  OWNER_EMAIL=$PRINCIPAL_ID
else
  echo "$PRINCIPAL_ID is an unexpected format" >&2
  exit 1
fi

RESOURCE_ID=${STACK_ID##*/}
PRODUCTS=$(/usr/bin/aws --region $AWS_REGION \
  servicecatalog search-provisioned-products \
  --filters SearchQuery=$RESOURCE_ID )
NUM_PRODUCTS=$(echo $PRODUCTS | jq -r '.TotalResultsCount')
if [ "$NUM_PRODUCTS" -ne 1 ]
then
  echo "ERROR: there are $NUM_PRODUCTS provisioned products, cannot isolate a name for tagging."
  exit 1
fi
PRODUCT_NAME=$(echo $PRODUCTS | jq -r '.ProvisionedProducts[0].Name')

mkdir -p /opt/sage/bin
OUTPUT_FILE=/opt/sage/bin/instance_env_vars.sh

cat > "$OUTPUT_FILE" << EOM
export AWS_REGION=$AWS_REGION
export STACK_NAME=$STACK_NAME
export STACK_ID=$STACK_ID
export EC2_INSTANCE_ID=$EC2_INSTANCE_ID
export ROOT_DISK_ID=$ROOT_DISK_ID
export DEPARTMENT=$DEPARTMENT
export PROJECT=$PROJECT
export ACCESS_APPROVED_ROLEID=$ACCESS_APPROVED_ROLEID
export OWNER_EMAIL=$OWNER_EMAIL
export OIDC_USER_ID=$PRINCIPAL_ID 
export OIDC_USERNAME=$SYNAPSE_USERNAME
export PRODUCT_NAME=$PRODUCT_NAME
EOM
