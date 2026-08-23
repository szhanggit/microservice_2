# microservice2

A demonstration of a multi-environment promotion pipeline, not a demonstration of an application. The app itself is deliberately trivial — a single static page — so nothing distracts from the thing actually being shown: a 4-branch Git workflow (`feature → develop → staging → master`) that promotes changes through three **fully independent** AWS environments, each with its own VPC, EKS cluster, and domain, driven entirely by GitHub Actions with OIDC (no static AWS keys).

## The pipeline

```
feature/*  --PR-->  develop   --PR-->  staging   --PR-->  master
                        │                  │                 │
                     push triggers      push triggers     push triggers
                        ▼                  ▼                 ▼
                  dev environment   staging environment  production environment
              dev_microservice_2.ekslab.xyz  staging_microservice_2.ekslab.xyz  microservice_2.ekslab.xyz
```

Each environment is a **separate EKS cluster in a separate VPC** (`microservice2-develop`, `microservice2-staging`, `microservice2-production`), not a namespace on a shared cluster — provisioned by the sibling [`microservice_2_terraform`](../microservice_2_terraform) repo. A push to `develop`/`staging`/`master` runs tests, builds and pushes a Docker image to that environment's own ECR repository, and deploys it via Helm — all in one `deploy.yml` workflow, branch-to-environment mapping handled by a single shell `case`.

## The app

A single-page Angular app, served by Nginx, showing three things baked in at Docker build time (`components/frontend/scripts/generate-build-info.js`, run before every build):

- **Environment name** (`NG_APP_ENV` build arg — `develop`/`staging`/`production`, or `local` for `docker compose`)
- **Deployment timestamp** (build time, not request time)
- **Version** — the git commit short SHA, the same value used as the Docker image tag

This exists specifically so that visiting each environment's URL after a deploy proves, at a glance, which commit is actually live there — the whole point of a promotion pipeline is being able to answer that question with confidence.

```bash
cd components/frontend
docker compose up --build   # http://localhost:8080, NG_APP_ENV=local
curl localhost:8080/health  # plain 200, also the k8s readiness/liveness target
```

## Why the domains use underscores

`dev_microservice_2.ekslab.xyz` and `staging_microservice_2.ekslab.xyz` look like typos but aren't. The ACM certificate shared with `microservice_0` is a single-level wildcard (`*.ekslab.xyz`), which only covers one label of subdomain depth. `dev.microservice_2.ekslab.xyz` (a dot) would be two labels deep and fail TLS validation against that wildcard; `dev_microservice_2.ekslab.xyz` (an underscore) stays at one label, which the wildcard actually covers.

## Deployment (Helm on EKS)

The Helm chart is intentionally minimal — a static Nginx server needs none of the machinery a stateful backend service would: no ConfigMap (the image already has everything baked in), no HPA or PodDisruptionBudget (fixed replica counts per environment instead — develop 1, staging 2, production 3, in `helm/values-<env>.yaml`), and both readiness and liveness probes point at the same `/health` endpoint since a static server has no meaningful startup/ready/live distinction.

```bash
cd helm
just deploy-app develop            # or staging / production
just rollback develop              # helm rollback, to previous or a specified revision
just destroy-app develop           # helm uninstall --wait, then cleans up ExternalDNS's Route53 records
```

There's no SSM Parameter Store lookup here (unlike sibling projects) — `deploy-app.sh` derives the ECR image URL directly from `aws sts get-caller-identity` and this project's fixed per-environment naming convention (`microservice2-<env>/frontend`), since there's no data layer or other dynamic infra output that would justify the indirection.

## CI/CD (`.github/workflows/`)

- **`deploy.yml`** — triggers on push to `develop`, `staging`, or `master`. One job, no separate test-gating stage: checkout → resolve environment name (`master` maps to `production`; the other two branch names pass through unchanged) → `npm ci` + `ng test --watch=false --browsers=ChromeHeadless` → assume the OIDC role and point `kubectl`/`helm` at that environment's cluster (via the shared `aws-eks-context` composite action) → build and push the Docker image to that environment's ECR repo, tagged with the git short SHA → `helm/scripts/deploy-app.sh`.
- **`rollback.yml`** — manual (`workflow_dispatch`), environment + optional revision, calls `helm/scripts/rollback.sh` directly for an instant rollback without waiting on a rebuild.
- **`destroy.yml`** — manual, requires retyping the environment name to confirm, tears down only the Helm release and its Route53 records for that environment — the EKS cluster, VPC, and ECR repos are untouched (use `microservice_2_terraform`'s own destroy path for that).
- All three use **OIDC** via a shared composite action (`.github/actions/aws-eks-context`) — no static AWS keys.
- Primary rollback path is a plain `git revert` through the normal pipeline; `rollback.yml` exists for the case where waiting on a full rebuild isn't acceptable.

## Repository layout

```
microservice_2/
├── components/frontend/     Angular app + Dockerfile + nginx.conf + local docker-compose
├── helm/                    single-component Helm chart (Deployment/Service/Ingress)
│   ├── values.yaml          shared defaults (image left blank, shared ACM cert ARN)
│   ├── values-<env>.yaml    per-environment replica count + domain
│   └── scripts/             deploy-app.sh, destroy-app.sh, rollback.sh, cleanup-dns.sh
├── .github/
│   ├── workflows/           deploy.yml, rollback.yml, destroy.yml
│   └── actions/aws-eks-context/   shared OIDC + kubeconfig composite action
└── Documents/               overview.md + step1-5.md: the staged build plan used to
                              build this project with Claude Code, one file per milestone
```

Terraform infrastructure lives in a separate sibling repo, [`microservice_2_terraform`](../microservice_2_terraform) — not part of this one, following the same convention as the other `microservice_*` projects in this portfolio.

## Design notes

- **The app is deliberately as simple as possible.** There's no backend, no database, no API — the entire point of this project is the branch-to-environment promotion pipeline and the fully-isolated-per-environment infrastructure underneath it, not the application logic on top.
- **ALB Controller and ExternalDNS are installed by Terraform itself** (via its own Helm provider), not by an imperative script in this repo — unlike the sibling `microservice_0`/`microservice_1` projects, where those controllers are IRSA-only in Terraform and get their actual Helm install from a separate app-deploy pipeline. That's why this repo's `helm/scripts/` has no `install-alb-controller.sh` or `install-external-dns.sh` — `microservice_2_terraform apply` alone stands up a cluster with working Ingress and DNS.
- **`Documents/step5.md` (branch protection rules, a PR template, auto-tagging on staging/prod merges) is a written plan, not yet implemented.** There is no `.github/PULL_REQUEST_TEMPLATE.md` in this repo, and branch protection rules are a GitHub repo setting rather than a file this repository can show — treat that step as the next piece of unfinished work, not something already in place.
- **No "does the cluster exist" skip step in `deploy.yml`**, unlike the sibling projects' cost-conscious "torn down between sessions" pattern — this pipeline assumes all three environments' clusters are up when it runs.
