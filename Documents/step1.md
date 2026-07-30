Study every single file in D:\git\microservice_0\terraform
Create a terraform project following the pattern above in D:\git\microservice_2_terraform.

Create Terraform configuration for 3 separate EKS clusters on AWS (develop, staging, production
are fully independent clusters, not namespaces on a shared cluster) with:
- Managed node groups (t3.small instances)
- AWS Load Balancer Controller installation
- IAM OIDC provider configuration
- ECR repositories (needed by step4's CI/CD pipeline to push images)
- Output kubeconfig setup commands

Do not include modules that aren't needed for this project (no cluster-autoscaler, ebs-csi,
external-dns, container-insights, x-ray, rds, or frontend-cdn) - this is a static Angular+Nginx
site with no backend/DB.

Only reuse the reference project's *pattern* (per-environment folder layout, module structure,
S3-native state locking). Do not share any actual AWS resources (VPC, cluster, state bucket
contents, etc.) with D:\git\microservice_0\terraform.

In this terraform project, service name is microservice2.

AWS region: ca-central-1

Cluster name in develop environment is microservice2-develop.
Cluster name in staging environment is microservice2-staging.
Cluster name in production environment is microservice2-production.

Networking: 3 separate VPCs, one per environment, fully isolated (no VPC peering).

For develop environment, terraform.tfstate shall be stored at Amazon S3 => Buckets => steven-zhang-learning => microservice2_dev/terraform.tfstate
For staging environment, terraform.tfstate shall be stored at Amazon S3 => Buckets => steven-zhang-learning => microservice2_stage/terraform.tfstate
For production environment, terraform.tfstate shall be stored at Amazon S3 => Buckets => steven-zhang-learning => microservice2_prod/terraform.tfstate

The steven-zhang-learning bucket already exists and is reused for state storage only (new
folders/keys under it, no other resources shared with other projects).

You can make D:\git\microservice_0\terraform as your reference.
Change names to fit this project.
Do not copy components which is not needed in this project.

## Implementation Plan

### Repo layout (D:\git\microservice_2_terraform)

```
microservice_2_terraform/
├── backend.tf                  # S3 backend, bucket/key/region left blank
│                                # (filled per-env via -backend-config), use_lockfile = true
├── main.tf                     # root module wiring: vpc, eks_cluster, eks_nodegroup,
│                                # eks_alb_controller, ecr
├── variables.tf
├── outputs.tf                  # kubeconfig setup command per cluster
├── modules/
│   ├── vpc/
│   ├── eks-cluster/
│   ├── eks-nodegroup/
│   ├── eks-alb-controller/
│   └── ecr/
├── environments/
│   ├── develop/
│   │   ├── backend.tfvars      # bucket=steven-zhang-learning, key=microservice2_dev/terraform.tfstate
│   │   └── develop.tfvars      # cluster_name=microservice2-develop, vpc_cidr_block, azs, node sizing
│   ├── staging/
│   │   ├── backend.tfvars      # key=microservice2_stage/terraform.tfstate
│   │   └── staging.tfvars      # cluster_name=microservice2-staging
│   └── production/
│       ├── backend.tfvars      # key=microservice2_prod/terraform.tfstate
│       └── production.tfvars   # cluster_name=microservice2-production
├── scripts/
│   └── bootstrap-backend.sh    # idempotent: versioning/encryption/public-access-block
│                                # on steven-zhang-learning (bucket already exists, so this
│                                # mainly verifies settings rather than creating it)
├── justfile                    # bootstrap-backend, init/plan/apply/destroy <env>
└── .gitignore                  # *.tfvars, .terraform/, *.tfstate*
```

One root module reused by all three environments (same pattern as the reference project):
each environment only swaps `-backend-config` (state key) and `-var-file` (cluster name, CIDR,
node sizing), so develop/staging/production get fully independent VPCs, clusters, node groups,
ALB controllers, and ECR repos out of the same code.

### Steps

1. **Scaffold root config** — `backend.tf` (S3 backend, blank bucket/key/region, `use_lockfile = true`,
   `encrypt = true`, no DynamoDB table), provider blocks (`aws ~> 5.39`, `tls ~> 4.0`,
   `kubernetes ~> 2.38`), `data "aws_caller_identity" "current"`.
2. **Port `vpc` module** — one VPC per environment: public + private subnets across 2 AZs
   (`ca-central-1a` / `ca-central-1b`), NAT gateway, route tables. Rename resources/tags to
   `microservice2-*`.
3. **Port `eks-cluster` module** — cluster control plane + IAM OIDC provider. Drop the
   reference's `additional_admin_role_arn` wiring for the GitHub Actions OIDC role, since this
   project has no `github-actions-oidc` state yet (leave the variable defaulted to empty — CI/CD
   IAM access is out of scope for step1, revisit when step4 is implemented).
4. **Port `eks-nodegroup` module** — managed node group, `t3.small`, one per environment with
   its own min/max/desired size.
5. **Port `eks-alb-controller` module** — IAM policy + IRSA role + Helm release of the AWS Load
   Balancer Controller, scoped to each cluster's OIDC provider.
6. **Port `ecr` module** — one repository set per environment (prefixed by cluster name, same as
   the reference), for the Angular+Nginx image `step4` will push.
7. **Wire root `main.tf`** — `vpc → eks_cluster → eks_nodegroup → eks_alb_controller`/`ecr`
   `depends_on` chain, matching the reference project's module ordering.
8. **`outputs.tf`** — emit `aws eks update-kubeconfig --region ca-central-1 --name <cluster_name>`
   per environment.
9. **Populate `environments/<env>/*.tfvars`** with defaults (adjust later if needed):
   - CIDR ranges: develop `10.0.0.0/16`, staging `10.1.0.0/16`, production `10.2.0.0/16`
   - Node sizing: develop `min=1 desired=1 max=2`, staging `min=1 desired=1 max=2`,
     production `min=2 desired=2 max=3`
   - Kubernetes version: latest EKS-supported version at apply time (currently 1.31)
10. **`scripts/bootstrap-backend.sh`** — adapt from the reference, pointed at
    `steven-zhang-learning` (already exists, so this only verifies versioning/encryption/
    public-access-block rather than creating the bucket).
11. **`justfile`** — `bootstrap-backend`, `init <env>`, `plan <env>`, `apply <env>`,
    `destroy <env>` targets, matching the reference project's commands.
12. **`.gitignore`** — `*.tfvars` (except checked-in non-secret ones, if any), `.terraform/`,
    `*.tfstate*`.
13. **Validate before applying** — `terraform fmt`, `terraform validate`, and
    `terraform plan` for each environment. Hold off on `terraform apply` (real AWS resources,
    real cost across 3 EKS clusters) until explicitly confirmed.

### Open items deferred past step1

- GitHub Actions OIDC IAM role (needed by step4's pipeline to authenticate to AWS) — not part
  of this plan; revisit when step4 is implemented.
- ECR repo/image naming vs. step2's tag pattern (`${REPO}:${ENV}-${GIT_SHA}`) — confirm whether
  this means one shared repo tagged per environment, or the per-environment repos this plan
  creates, once step2/step4 are wired up.
