Generate K8s deployment files with helm.
Code shall be stored in D:\git\microservice_2\helm.

Reference: D:\git\microservice_0\Helm (single-service chart pattern, not the full multi-service
setup - most of that project's DB/Alloy/X-Ray/gRPC-specific pieces don't apply here).

1. Namespace: dedicated "frontend" namespace in each cluster (environments are separate
   clusters, not namespaces - the namespace value here is just organizational within each
   cluster, same value across all three environments).

2. Ingress:
   - ALB (AWS Load Balancer Controller), ingressClassName: alb
   - Real domains from overview.md: dev.microservice_2.ekslab.xyz, staging.microservice_2.ekslab.xyz,
     microservice_2.ekslab.xyz (one per environment, via a values-<env>.yaml)
   - HTTPS via ACM certificate: arn:aws:acm:ca-central-1:286664220642:certificate/79114ecf-5ba1-4fac-a025-4709372825fe
     (a shared multi-SAN cert also covering microservice_0's domain - confirmed intentional)
   - ssl-redirect 443, healthcheck-path /health (matches step2's Nginx health endpoint)
   - external-dns.alpha.kubernetes.io/hostname annotation set to the environment's domain, so
     ExternalDNS creates the Route53 record automatically

3. ExternalDNS: reopens step1's Terraform scope. Add a modules/eks-external-dns module
   (IRSA role + helm_release), same Terraform-managed pattern as the existing
   eks-alb-controller module - not a separate imperative script like the reference project.
   policy=upsert-only, txtOwnerId=cluster_name, domainFilters=[ekslab.xyz] (ekslab.xyz is a
   shared personal domain used by other projects too, so ExternalDNS must never delete records
   it didn't create, and develop/staging/production must not fight over TXT ownership).

4. Image: chart's values.yaml leaves image.repository/tag blank, supplied via
   `--set image.repository=... --set image.tag=$GIT_SHA` at deploy time (step4's CI/CD) -
   matches step1's per-environment ECR layout and step2's tag scheme.

5. No HPA, no PodDisruptionBudget - fixed replica counts per environment instead
   (develop=1, staging=2, production=3), set directly in each values-<env>.yaml.

6. No SSM Parameter Store indirection - cluster name, ECR repo URLs, and domains are passed
   into deploy scripts/CI directly (step4's GitHub Actions secrets), not looked up dynamically.

7. Resources: single "frontend" Deployment (Nginx + built Angular static files, image from
   step2) + ClusterIP Service (port 80) + the Ingress described above. No ConfigMap needed -
   step2 already bakes NG_APP_ENV/timestamp/git SHA into the image at build time, so there's no
   runtime env var to inject via Kubernetes.

## Implementation Plan

### Part A - Terraform addition (D:\git\microservice_2_terraform), needed before step3 can work

```
modules/eks-external-dns/
├── main.tf        # data "aws_route53_zone" lookup, IRSA role, IAM policy, k8s ServiceAccount,
│                   # helm_release (external-dns chart, namespace "default")
├── variables.tf    # cluster_name, region, domain_name, oidc_provider_arn, oidc_provider_url
└── outputs.tf       # external_dns_role_arn
```

1. `data "aws_route53_zone" "domain"` - looks up the existing ekslab.xyz zone by name
   (confirmed already registered/delegated), not created by Terraform.
2. IAM policy scoped to that zone: `route53:ChangeResourceRecordSets` on the specific
   hosted zone ARN, plus account-wide `route53:ListHostedZones` /
   `route53:ListResourceRecordSets` (ExternalDNS needs these to discover the zone).
3. IRSA role + trust policy for `system:serviceaccount:default:external-dns` (ExternalDNS runs
   in the `default` namespace, same as the reference project - it's cluster-level infra, not
   part of the app's own "frontend" namespace).
4. `helm_release` installing `external-dns/external-dns` from
   `https://kubernetes-sigs.github.io/external-dns/`, with `policy=upsert-only` and
   `txtOwnerId=var.cluster_name` (so ekslab.xyz's other tenants are never touched, and
   develop/staging/production never fight over the same TXT ownership records) and
   `domainFilters=[ekslab.xyz]`.
5. Wire `module "eks_external_dns"` into root `main.tf` (same shape as `eks_alb_controller`),
   add `route53_domain` (default `"ekslab.xyz"`) to root `variables.tf`.
6. Re-apply all 3 environments (`just apply develop|staging|production`) to pick up the new
   module before step3's Helm release is deployed anywhere.

### Part B - Helm chart (D:\git\microservice_2\helm)

```
helm/
├── Chart.yaml
├── values.yaml                    # defaults: image left blank, cert ARN, blank domain
├── values-develop.yaml            # replicas: 1, domain: dev.microservice_2.ekslab.xyz
├── values-staging.yaml            # replicas: 2, domain: staging.microservice_2.ekslab.xyz
├── values-production.yaml         # replicas: 3, domain: microservice_2.ekslab.xyz
├── .helmignore
├── justfile                       # update-kubeconfig, deploy-app, destroy-app, rollback
├── templates/
│   ├── _helpers.tpl               # frontend.labels helper; fixed resource names (no
│   │                               # {{ .Release.Name }} templating - one release per
│   │                               # cluster, nothing needs to vary by release name)
│   ├── namespace.yaml
│   ├── frontend/
│   │   ├── deployment.yaml        # readiness/liveness probes both on /health - a static
│   │   │                           # Nginx server has no meaningful startup/ready/live
│   │   │                           # distinction, unlike the reference's .NET services
│   │   └── service.yaml           # ClusterIP, port 80
│   ├── ingress.yaml                # ALB + ExternalDNS annotations, cert ARN, healthcheck-path /health
│   └── NOTES.txt
└── scripts/
    ├── update-kubeconfig.sh       # cluster name is deterministic (microservice2-<env>), no
    │                               # SSM lookup needed, unlike the reference project
    ├── deploy-app.sh              # helm upgrade --install, --set image.repository/tag,
    │                               # account ID via `aws sts get-caller-identity` (no SSM)
    ├── destroy-app.sh             # helm uninstall --wait, then cleanup-dns.sh
    ├── cleanup-dns.sh             # deletes Route53 records ExternalDNS created (it runs
    │                               # upsert-only and will never delete them itself) -
    │                               # scoped to only records owned by this cluster's txtOwnerId
    └── rollback.sh                # helm rollback frontend -n frontend [revision]
```

### Steps

1. **Terraform first** (Part A above) - step3's Ingress annotations assume ExternalDNS is
   already running in every cluster.
2. **`Chart.yaml`** - single-component chart, description noting the ALB controller and
   ExternalDNS are Terraform-managed, not part of this chart (mirrors the reference's
   Chart.yaml description).
3. **`values.yaml`** - `namespace: frontend`, `image.repository`/`image.tag` left blank
   (required via `--set` at deploy time), default `resources` (small - `cpu: 50m/200m`,
   `memory: 64Mi/128Mi`, a static Nginx server needs far less than the reference's .NET
   services), `ingress.certificateArn` (the confirmed shared cert), `ingress.domain`/
   `ingress.loadBalancerName` left blank (set per environment).
4. **`values-<env>.yaml`** - `replicas` (1/2/3), `ingress.domain`, `ingress.loadBalancerName`
   (e.g. `microservice2-develop-ingress`) per environment.
5. **`templates/namespace.yaml`**, **`templates/_helpers.tpl`** - straight port of the
   reference's pattern, renamed.
6. **`templates/frontend/deployment.yaml`** - single container, port 80, readiness/liveness
   probes on `/health`, resources from values, `image: {{ .Values.image.repository }}:{{
   .Values.image.tag }}` with `required` guards on both.
7. **`templates/frontend/service.yaml`** - ClusterIP, port 80.
8. **`templates/ingress.yaml`** - port straight from the reference's annotations
   (load-balancer-name, healthcheck settings, `listen-ports` HTTPS+HTTP, `certificate-arn`,
   `ssl-redirect: '443'`, `external-dns.alpha.kubernetes.io/hostname`, `scheme:
   internet-facing`, `target-type: ip`, `healthcheck-path: /health`), single backend
   (`frontend` service, port 80).
9. **`templates/NOTES.txt`** - `kubectl get ingress` command + expected `https://<domain>`
   reachability once ExternalDNS picks up the record.
10. **`scripts/deploy-app.sh`** - resolves `ACCOUNT_ID` via `aws sts get-caller-identity`,
    builds `IMAGE_REPO=$ACCOUNT_ID.dkr.ecr.ca-central-1.amazonaws.com/microservice2-$ENV/frontend`,
    `helm upgrade --install frontend ./helm --namespace frontend --create-namespace -f
    values-$ENV.yaml --set image.repository=$IMAGE_REPO --set image.tag=$TAG --wait`.
11. **`scripts/destroy-app.sh`** / **`cleanup-dns.sh`** - capture the Ingress's ExternalDNS
    hostname before `helm uninstall --wait`, then delete the Route53 records it owns (same
    TXT-ownership-scoped logic as the reference, since `policy=upsert-only` means
    ExternalDNS never cleans up after itself).
12. **`scripts/update-kubeconfig.sh`**, **`scripts/rollback.sh`** - simplified ports of the
    reference (no SSM lookups, no WSL-specific kubeconfig mirroring).
13. **`justfile`** - `update-kubeconfig`, `deploy-app`, `destroy-app`, `rollback` recipes.
14. **Validate** - `helm lint` and `helm template ./helm -f values-develop.yaml --set
    image.repository=placeholder --set image.tag=placeholder` for all 3 environments before
    ever touching a real cluster.

### Open items deferred past step3

- Actually running `deploy-app.sh` against a live cluster depends on step1's Terraform
  (including the new eks-external-dns module) having been applied first.
- step4's CI/CD pipeline is what will call `scripts/deploy-app.sh` (or an equivalent
  `helm upgrade` step) per environment - no changes needed here, just keep it consistent
  when step4 is revisited.
