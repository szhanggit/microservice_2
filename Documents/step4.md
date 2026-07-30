Create GitHub Actions workflow with:

1. Trigger rules:
   - push to develop → deploy to dev (a PR merge lands as a push to the base branch - GitHub
     Actions has no separate "PR merge" event)
   - push to staging → deploy to staging
   - push to master → deploy to prod

2. AWS auth: GitHub OIDC, not static IAM keys. Reopens step1's Terraform scope again:
   - Add an IAM OIDC provider for token.actions.githubusercontent.com (account-wide, applied
     once - not per environment).
   - Add an IAM role trusted only by this repo (via the OIDC provider's condition on the GitHub
     token's `sub` claim), granted ECR push permissions and an EKS access entry on all 3
     clusters (this is exactly the `additional_admin_role_arn` input step1's eks-cluster module
     already supports but left blank - "no CI/CD deploy role exists yet").
   - Only the resulting role ARN needs to be a GitHub secret/variable - everything else
     (ECR repo URL, cluster name, domains) is computed the same way helm/scripts/deploy-app.sh
     already does (aws sts get-caller-identity + this project's fixed naming conventions), not
     stored as secrets.

3. Pipeline steps (on push to develop/staging/master):
   - Checkout code
   - Setup Node.js (20, matching step2's Dockerfile build stage)
   - Install dependencies (components/frontend)
   - Run unit tests as a gate: `ng test --watch=false --browsers=ChromeHeadless` - fail fast
     before spending time on a Docker build if tests break
   - Build Docker image (components/frontend/Dockerfile, NG_APP_ENV/GIT_SHA build args per
     step2)
   - Push to Amazon ECR - per-environment repo (microservice2-<env>/frontend, matches step1),
     tag is just the git SHA (matches step2/step3, no separate "env tag" needed since the repo
     name already identifies the environment)
   - Deploy: call helm/scripts/deploy-app.sh <env> <tag> directly - no separate "update K8s
     manifest image tag" / "kubectl apply" step, that logic already lives in the script step3
     built and validated end-to-end
   - Post deployment notification: GitHub's native deployment status only (visible on the
     commit/PR) - no external service/webhook

4. Rollback support:
   - Primary path: `git revert` the bad commit - the reverted code goes through the normal
     pipeline above (test -> build -> push -> deploy) like any other change
   - Also add a manually-triggered workflow (workflow_dispatch, inputs: env, optional revision)
     that calls helm/scripts/rollback.sh directly - instant rollback to a prior Helm release
     without waiting for a full rebuild

5. Destroy support:
   - Manually-triggered workflow (workflow_dispatch, required input: env) that calls
     helm/scripts/destroy-app.sh - removes the Helm release and its Route53 records for that
     environment only
   - App layer only - does not touch the underlying EKS cluster/VPC/ECR (those stay up; use
     microservice_2_terraform's own destroy path directly if the infrastructure itself needs to
     go away)

## Implementation Plan

### Part A - Terraform addition (D:\git\microservice_2_terraform), reopens step1 again

```
microservice_2_terraform/
├── github-actions-oidc/        # NEW - separate root module/state, applied ONCE (account-wide
│   │                            # singleton), not per environment
│   ├── backend.tf              # own S3 state key: microservice2_github_actions_oidc/terraform.tfstate
│   ├── main.tf                 # OIDC provider + IAM role + permissions policy
│   ├── variables.tf            # github_repo, role_name, region
│   └── outputs.tf              # github_actions_role_arn
├── main.tf                     # MODIFIED - data.aws_caller_identity, computed CI role ARN
│                                # passed into eks_cluster's additional_admin_role_arn
└── variables.tf                # MODIFIED - add github_actions_role_name variable
```

1. **`github-actions-oidc/main.tf`**:
   - `data "tls_certificate" "github_actions"` on `https://token.actions.githubusercontent.com`
     (same pattern step1's eks-cluster module already uses for its own OIDC provider).
   - `aws_iam_openid_connect_provider` for that URL, `client_id_list = ["sts.amazonaws.com"]`.
   - `aws_iam_role "github_actions"` trusted via `sts:AssumeRoleWithWebIdentity`, condition on
     `token.actions.githubusercontent.com:sub` scoped to `repo:szhanggit/microservice_2:*` -
     wildcarded across branches/workflows rather than enumerating each one, since this is a
     single personal repo (not scoping tighter per-branch for now).
   - Inline policy: ECR push actions scoped to `arn:aws:ecr:*:*:repository/microservice2-*/frontend`,
     `ecr:GetAuthorizationToken` (must be `Resource: "*"` - the action doesn't support
     resource-level scoping), `eks:DescribeCluster` scoped to `arn:aws:eks:*:*:cluster/microservice2-*`
     (needed for `aws eks update-kubeconfig`).
2. **Root `main.tf`/`variables.tf`** - add `data "aws_caller_identity" "current" {}` and
   `var.github_actions_role_name` (default `"microservice2-github-actions"`, matching
   `github-actions-oidc`'s `role_name` default), then wire
   `additional_admin_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.github_actions_role_name}"`
   into the `eks_cluster` module call - same trick the microservice0 reference project uses to
   avoid reading another Terraform state's output directly.
3. **Apply order**: `github-actions-oidc/` once, then re-apply all 3 environments
   (develop/staging/production) so each cluster picks up the new EKS access entry for the CI role.

### Part B - GitHub Actions (D:\git\microservice_2\.github)

```
.github/
├── workflows/
│   ├── deploy.yml           # push to develop/staging/master
│   ├── rollback.yml         # workflow_dispatch: environment, revision (optional)
│   └── destroy.yml          # workflow_dispatch: environment, confirm (must match environment)
└── actions/
    └── aws-eks-context/
        └── action.yml       # composite: configure-aws-credentials (OIDC) + update-kubeconfig.sh,
                              # shared by all 3 workflows instead of duplicating those steps 3x
```

4. **`aws-eks-context` composite action** - takes `role-to-assume` and `environment` inputs,
   runs `aws-actions/configure-aws-credentials@v4` (OIDC) then
   `helm/scripts/update-kubeconfig.sh <environment>`.
5. **`deploy.yml`**:
   - `on: push: branches: [develop, staging, master]`, `permissions: id-token: write, contents:
     read`.
   - Maps branch → environment name (`master` → `production`, others pass through unchanged -
     cluster/env naming already differs from branch naming this one place).
   - `environment: <mapped-name>` at the job level, for native GitHub deployment tracking
     (requires the `develop`/`staging`/`production` Environments to exist in repo settings
     first - see open items).
   - Steps: checkout → `actions/setup-node@v4` (Node 20) → `npm ci` + `npm run test --
     --watch=false --browsers=ChromeHeadless` in `components/frontend` → `aws-eks-context` →
     resolve short SHA (`git rev-parse --short HEAD`) and account ID (`aws sts
     get-caller-identity`) → `docker build`/`push` to
     `<account>.dkr.ecr.ca-central-1.amazonaws.com/microservice2-<env>/frontend:<sha>` →
     `helm/scripts/deploy-app.sh <env> <sha>`.
6. **`rollback.yml`** - `workflow_dispatch` inputs `environment` (choice: develop/staging/production)
   and `revision` (optional text) → `aws-eks-context` → `helm/scripts/rollback.sh <env>
   <revision>`.
7. **`destroy.yml`** - `workflow_dispatch` inputs `environment` (choice) and `confirm` (text,
   must exactly match `environment` - a safety gate since this deletes a live release, checked
   in a step before anything else runs) → `aws-eks-context` → `helm/scripts/destroy-app.sh <env>`.
8. **Repo configuration** (done via GitHub UI/settings, not YAML) - create the `develop`,
   `staging`, `production` Environments; add `AWS_ROLE_ARN` as a repository variable (not a
   secret - a role ARN isn't sensitive) set to `github-actions-oidc`'s output.

### Open items / prerequisites to resolve before this can run

- **Branch name resolved**: this repo's production branch is `master` (only one pushed to
  `origin`), not `main` - `deploy.yml` targets `master`, and `overview.md`/`step4.md`/`step5.md`
  have been updated to say `master` throughout instead of `main`.
- Chrome availability for `ng test --browsers=ChromeHeadless` on the `ubuntu-latest` runner is
  assumed (GitHub's runner images ship Chrome), but not verified against an actual workflow run
  yet - only verified locally in this session.
- The 3 GitHub Environments and the `AWS_ROLE_ARN` repository variable are manual one-time repo
  setup steps, not something this plan's files can create on their own.
