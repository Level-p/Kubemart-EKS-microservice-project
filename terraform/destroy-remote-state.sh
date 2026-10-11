#!/bin/bash
# ---------------------------------------------------------------------------
# Run LAST, after the main stack has been destroyed (GitHub Actions
# "KubeMart Infrastructure" workflow with action=destroy, or terraform destroy).
#   1. Destroys the bootstrap stack (GitHub OIDC role, ACM certificate)
#   2. Empties and deletes the state bucket (all object versions)
# Requires jq.
# ---------------------------------------------------------------------------

BUCKET_NAME="mfon21-eks-ecommerce-tfstate"
AWS_REGION="eu-west-2"
AWS_PROFILE="default"

echo "Destroying the bootstrap stack..."
(cd bootstrap && terraform init -input=false && terraform destroy -auto-approve)

echo "Deleting all objects in $BUCKET_NAME..."
DELETE_LIST=$(aws s3api list-object-versions \
  --bucket "$BUCKET_NAME" \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  --output json)

OBJECTS_TO_DELETE=$(echo "$DELETE_LIST" | jq '{
  Objects: (
    [.Versions[]?, .DeleteMarkers[]?]
    | map({Key: .Key, VersionId: .VersionId})
  ),
  Quiet: true
}')

NUM_OBJECTS=$(echo "$OBJECTS_TO_DELETE" | jq '.Objects | length')

if [ "$NUM_OBJECTS" -gt 0 ]; then
  echo "Deleting $NUM_OBJECTS objects from bucket: $BUCKET_NAME..."
  aws s3api delete-objects \
    --bucket "$BUCKET_NAME" \
    --delete "$OBJECTS_TO_DELETE" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE"
else
  echo "No objects or versions found in $BUCKET_NAME."
fi

echo "Deleting bucket: $BUCKET_NAME..."
aws s3api delete-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"

echo "Bucket $BUCKET_NAME deleted successfully."
