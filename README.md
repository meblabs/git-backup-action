# Git Backup Action

Composite GitHub Action that creates compressed mirror snapshots of every repository in a GitHub organisation and uploads them to an Amazon S3 bucket **without** storing long‑lived AWS credentials (OIDC‑based).

## How it works

1. **Enumerate repositories** – a GraphQL query lists all non‑fork repositories in the organisation.  
2. **Assume an AWS role via OIDC** – the action requests an OIDC token (`id‑token: write`). AWS STS exchanges it for temporary credentials for the IAM role you provide (`role‑to‑assume`).  
3. **Mirror & upload** – each repo is cloned with `git clone --mirror`, tar‑compressed, and uploaded to `s3://<bucket>/<prefix>/`.  
4. **Retention** – you manage retention with S3 Lifecycle rules (e.g. delete `daily/` after 7 days, etc.).

No static AWS keys are stored in GitHub.


## Inputs

| Name           | Required | Description                                         |
|----------------|----------|-----------------------------------------------------|
| `token`       | ✔︎       | Personal access token to handle the repos |
| `org`          | ✔︎       | GitHub organisation to back up                      |
| `s3-bucket`    | ✔︎       | Destination S3 bucket                               |
| `role-to-assume` | ✔︎     | IAM role ARN to assume via OIDC                     |
| `aws-region`   |          | AWS region (default `eu-west-1`)                    |
| `prefix`       | ✔︎       | Sub‑folder in the bucket (`daily`, `weekly`, `monthly`) |


## AWS setup (one‑time per AWS account)

You can use the provided `setup.sh` script to automate the AWS setup. Just configure the required variables in the `.env` file before running the script.

Alternatively, if you prefer to use the AWS Console, follow the steps below.

1. **Create S3 bucket** – e.g. `git-backups` with default encryption and lifecycle rules:  
   * `daily/`  → delete after 7 days  
   * `weekly/` → delete after 28 days  
   * `monthly/` → delete after 365 days

   Setting the rule 
   1. Open **S3 → Buckets → _your bucket_ → Management → Lifecycle rules → Create rule**  
   2. Rule name: `git-backup-retention`  
   3. Under **Filter**, choose **Prefix** and type `daily/`  
   4. Under **Lifecycle rule actions**, enable **Expire current versions** and set **7 days**  
   5. Choose **Add lifecycle rule action**, select **Expire current versions**, set **28 days**, and type prefix `weekly/`  
   6. Again choose **Add lifecycle rule action**, select **Expire current versions**, set **365 days**, and type prefix `monthly/`  
   7. Click **Create rule** to save.  

2. **Create the OIDC identity provider in AWS**  
   IAM → **Identity providers** → *Add provider* → **OpenID Connect**  
   • Provider URL: `https://token.actions.githubusercontent.com`  
   • Audience (Client ID): `sts.amazonaws.com`

3. **Create s3 policy** (e.g. `github-backup-policy`) 
    ```json
     {
       "Version": "2012-10-17",
       "Statement": [
         {
           "Sid": "GitBackupAccess",
           "Effect": "Allow",
           "Action": [
             "s3:PutObject",
             "s3:GetObject",
             "s3:ListBucket"
           ],
           "Resource": [
             "arn:aws:s3:::<YOUR_BUCKET_NAME>",
             "arn:aws:s3:::<YOUR_BUCKET_NAME>/*"
           ]
         }
       ]
     }
     ```

4. **Create the IAM role** that the workflow will assume (e.g. `github-backup`)  
   IAM → **Roles** → *Create role* → **Web identity**  
   • Identity provider: `token.actions.githubusercontent.com`  
   • Audience: `sts.amazonaws.com`  
   • Trust policy: use the JSON in the “Prerequisites” section (update `YOURORG` and bucket names)  
   • Permissions: attach the **S3 policy** shown earlier (`GitBackupAccess`).


## Usage 

1. **Create a repo** in the organisation (e.g. `git-backup`) and add this action.

2. **Add the workflow** `.github/workflows/backup.yml`:

```yaml
name: Backup organisation repositories
on:
  schedule:
    - cron: '0 2 * * *'  
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - id: when
        run: |
          PREFIX=daily
          [[ $(date -u +%u) == 7 ]] && PREFIX=weekly      # Sunday
          [[ $(date -u +%d) == 01 ]] && PREFIX=monthly    # 1st day of month
          echo "prefix=$PREFIX" >> "$GITHUB_OUTPUT"

      - uses: meblabs/git-backup-action@v1
        with:
          org:           your-org
          s3-bucket:     org-git-backups
          role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/github-backup
          aws-region:    eu-west-1
          prefix:        ${{ steps.when.outputs.prefix }}
          token:         ${{ secrets.<PAT> }}
```

## Restoring a repository

```bash
aws s3 cp s3://org-git-backups/weekly/myrepo-2025-07-03T030000.git.tar.gz .
tar xzf myrepo-*.tar.gz
cd myrepo.git
git remote add origin git@github.com:YOURORG/myrepo.git
git push --mirror origin
```

Feel free to adjust the schedule or lifecycle settings to match your retention policy.
