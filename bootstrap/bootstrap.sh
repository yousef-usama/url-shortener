#!/bin/bash
# bootstrap.sh
# Run this ONCE before your first `terraform init`.
# Creates the S3 bucket that stores your Terraform state file remotely.
#
# Usage: bash bootstrap/bootstrap.sh

set -e

REGION="eu-central-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="url-shortener-tfstate-${ACCOUNT_ID}"

echo "Creating Terraform state bucket: $BUCKET_NAME"

aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

# Block all public access (security best practice)
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Enable versioning so you can recover from a bad state file
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

# Enable server-side encryption
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo ""
echo "Done! Now open terraform/main.tf, uncomment the backend block,"
echo "and replace <your-account-id> with: $ACCOUNT_ID"
echo ""
echo "Then run: cd terraform && terraform init"
