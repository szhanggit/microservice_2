Build a simple Angular app. This app only shows one static page.
It needs to show enviornment information on page.
It also needs to show hard coded version information on page.
The app needs to stay in D:\git\microservice_2\components\frontend.
Only the frontend app moves under components/ - kubernetes/ and .github/ stay at the repo root.

1. Angular app:
   - Display current environment name (from env var, baked in at build time via NG_APP_ENV)
   - Show deployment timestamp (build-time)
   - Show version information: the git commit SHA, injected at build time (same GIT_SHA used
     in the image tag) - not a manually maintained constant
   - Simple "Hello World" page

2. Web server: Nginx, via a multi-stage Dockerfile
   - Stage 1: Node builds the Angular app (NG_APP_ENV passed as a build arg)
   - Stage 2: Nginx serves the built static files
   - Health check endpoint: /health (plain 200 OK) - needed for k8s liveness/readiness probes
     and scripts/verify-deployment.sh

3. Need to build docker and docker compose file for this app.
   - docker-compose defaults NG_APP_ENV to "local" for local development

4. Expose port 80

5. Build script with env injection (NG_APP_ENV)
   - ECR layout matches the Terraform in step1: one repository per environment
     (microservice2-develop/frontend, microservice2-staging/frontend,
     microservice2-production/frontend), not one shared repository.
   - Image tag is just the git SHA (the repo name already identifies the environment):
     ${REPO}:${GIT_SHA}

## Implementation Plan

### Repo layout (D:\git\microservice_2\components\frontend)

```
components/frontend/
├── src/
│   ├── app/
│   │   ├── app.component.ts       # single "Hello World" page, reads ./build-info
│   │   ├── app.component.html
│   │   └── build-info.ts          # generated at build time, gitignored (see below)
│   ├── index.html
│   └── main.ts
├── scripts/
│   └── generate-build-info.js     # writes src/app/build-info.ts before every build/serve
├── angular.json
├── package.json
├── Dockerfile                     # multi-stage: Node build -> Nginx serve
├── nginx.conf
├── docker-compose.yml
├── .dockerignore
└── .gitignore                     # excludes src/app/build-info.ts, dist/, node_modules/
```

### Steps

1. **Scaffold the Angular app** — `ng new frontend` (standalone components, no routing needed
   for a single static page), Node 20 LTS, latest stable Angular CLI at implementation time.
   Move/rename output into `components/frontend`.
2. **Build-time value injection** — rather than Angular's static `environment.<name>.ts` file
   replacement (which can't express a per-build timestamp or git SHA), use a small Node script
   run before every build/serve:
   - `scripts/generate-build-info.js` reads `NG_APP_ENV` and `GIT_SHA` from the process
     environment (falling back to `"local"` / `"dev"` if unset), stamps the current time, and
     writes `src/app/build-info.ts` exporting `{ environment, timestamp, gitSha }`.
   - `package.json` scripts: `"generate:build-info": "node scripts/generate-build-info.js"`,
     with `build` and `start` both running it first (`"build": "npm run generate:build-info &&
     ng build"`).
   - `src/app/build-info.ts` is gitignored (generated, not checked in).
3. **`AppComponent`** — single page: "Hello World" heading, plus environment name, deployment
   timestamp, and git SHA read from `./build-info`.
4. **`Dockerfile`** (multi-stage):
   - Stage 1 (`node:20-alpine`): `npm ci`, `ARG NG_APP_ENV` / `ARG GIT_SHA` promoted to `ENV`
     so the build script picks them up, `npm run build -- --configuration production`.
   - Stage 2 (`nginx:1.27-alpine`): copy the compiled output into
     `/usr/share/nginx/html`, copy in `nginx.conf`, `EXPOSE 80`.
   - Note: confirm the actual `ng build` output path during implementation (Angular's esbuild
     application builder defaults to `dist/frontend/browser`, older configs may output directly
     to `dist/frontend`) — don't hardcode blindly, verify against this project's `angular.json`.
5. **`nginx.conf`** — serve static files with SPA fallback (`try_files ... /index.html`), gzip
   enabled for text/css/js/json/svg, and a `/health` location returning a plain `200 healthy`.
6. **`docker-compose.yml`** — single `frontend` service, build args
   `NG_APP_ENV=local`/`GIT_SHA=local-dev`, port mapping (e.g. `8080:80`).
7. **`.dockerignore`** — `node_modules/`, `dist/`, `.angular/`.
8. **Local build/tag script** (`scripts/build-image.sh`) — for local testing only (step4 owns
   the real CI/CD push+deploy pipeline): takes an environment name, resolves
   `GIT_SHA=$(git rev-parse --short HEAD)`, builds with the matching build args, and tags
   `<ecr-registry>/microservice2-<env>/frontend:$GIT_SHA` per the confirmed ECR layout.
9. **Validate** — `docker compose up --build` locally, confirm the page shows `local` /
   a timestamp / a git SHA, and `curl localhost:8080/health` returns 200.

### Open items deferred past step2

- Actually pushing images to ECR and deploying to a cluster is step4's job (GitHub Actions
  pipeline) — `scripts/build-image.sh` here only builds/tags locally.
- Kustomize overlays (step3) will need to reference whichever image tag scheme this produces;
  no changes needed here, just keep step3 consistent when it's revisited.
