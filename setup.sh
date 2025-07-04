#!/usr/bin/env bash
#
# Automates all AWS prerequisites for GitHub‑>S3 backups:
#   * S3 bucket + lifecycle rules
#   * OIDC identity provider for GitHub Actions
#   * IAM policy & role to allow S3 writes from the workflow
#
#   Define the following variables in `.env`
#     AWS_PROFILE           = aws cli profile to use
#     AWS_DEFAULT_REGION    = aws cli region to use
#     ACCOUNT_ID            = AWS account ID (12‑digit)
#     BUCKET                = target S3 bucket
#     ORG                   = GitHub organisation
#   Then run:
#     ./setup.sh
#
# Prerequisites:
#   * The AWS CLI is configured with a profile able to create IAM/S3 resources.
#   * `jq` installed (for simple JSON parsing).
#

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. ENV & ARG CHECKS
# ---------------------------------------------------------------------------
source .env

: "${BUCKET:?BUCKET not set in .env}"
: "${ORG:?ORG not set in .env}"
: "${ACCOUNT_ID:?ACCOUNT_ID not set in .env}"

ROLE_NAME="github-backup"
POLICY_NAME="GitBackupAccess"
OIDC_URL="https://token.actions.githubusercontent.com"
REGION="${AWS_DEFAULT_REGION}"
BACKUP_REPO="${BACKUP_REPO:-git-backup}"

echo "AWS_PROFILE:         ${AWS_PROFILE}"
echo "AWS_DEFAULT_REGION:  ${REGION}"
echo "Bucket:              ${BUCKET}"
echo "GitHub Org:          ${ORG}"
echo "AWS Account ID:      ${ACCOUNT_ID}"
echo "Backup Repo name:    ${BACKUP_REPO}"
echo "----------------------------------------------------"

export AWS_PROFILE=${AWS_PROFILE}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}
export AWS_PAGER=""

# ---------------------------------------------------------------------------
# 2. S3 BUCKET + LIFECYCLE
# ---------------------------------------------------------------------------
echo ">> Creating (or confirming) S3 bucket..."
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --create-bucket-configuration LocationConstraint="$REGION"
  echo "   Bucket created."
else
  echo "   Bucket exists."
fi

echo ">> Enabling default encryption (SSE-KMS)..."
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration '{
  "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'

echo ">> Applying lifecycle configuration..."
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules":[
    {"ID":"daily-expire-7d","Prefix":"daily/","Status":"Enabled","Expiration":{"Days":7}},
    {"ID":"weekly-expire-28d","Prefix":"weekly/","Status":"Enabled","Expiration":{"Days":28}},
    {"ID":"monthly-expire-365d","Prefix":"monthly/","Status":"Enabled","Expiration":{"Days":365}}
  ]}'

# ---------------------------------------------------------------------------
# 3. OIDC IDENTITY PROVIDER
# ---------------------------------------------------------------------------
echo ">> Ensuring OIDC provider..."
PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" 2>/dev/null; then
  # Obtain SHA1 thumbprint of GitHub's TLS cert (lowercase, no colons)
  THUMBPRINT=$(echo | openssl s_client -servername token.actions.githubusercontent.com -showcerts -connect token.actions.githubusercontent.com:443 2>/dev/null \
               | openssl x509 -fingerprint -sha1 -noout \
               | cut -d'=' -f2 | tr -d ':' | tr 'A-Z' 'a-z')
  aws iam create-open-id-connect-provider \
    --url "$OIDC_URL" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list "$THUMBPRINT"
  echo "   OIDC provider created."
else
  echo "   OIDC provider exists."
fi

# ---------------------------------------------------------------------------
# 4. IAM POLICY
# ---------------------------------------------------------------------------
echo ">> Creating/attaching IAM policy..."
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GitBackupAccess",
      "Effect": "Allow",
      "Action": ["s3:PutObject","s3:GetObject","s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::${BUCKET}",
        "arn:aws:s3:::${BUCKET}/*"
      ]
    }
  ]
}
EOF
)

if ! aws iam get-policy --policy-arn "$POLICY_ARN" 2>/dev/null; then
  aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "$POLICY_DOC" >/dev/null
  echo "   Policy created."
else
  echo "   Policy exists."
fi

# ---------------------------------------------------------------------------
# 5. IAM ROLE
# ---------------------------------------------------------------------------
echo ">> Creating (or updating) IAM role..."
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "${PROVIDER_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${ORG}/${BACKUP_REPO}:*"
        }
      }
    }
  ]
}
EOF
)

if ! aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" >/dev/null
  echo "   Role created."
else
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST_POLICY"
  echo "   Role trust policy updated."
fi

echo ">> Attaching policy to role..."
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true

echo "Setup complete ✅"