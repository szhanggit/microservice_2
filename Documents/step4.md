Create GitHub Actions workflow with:

1. Trigger rules:
   - push to develop → deploy to dev
   - push to staging → deploy to staging
   - push to main → deploy to prod

2. Pipeline steps:
   - Checkout code
   - Setup Node.js
   - Install dependencies
   - Build Docker image
   - Push to Amazon ECR (with env tags)
   - Update K8s manifest image tag
   - kubectl apply to target namespace
   - Post deployment notification

3. Secrets management:
   - AWS credentials (IAM role or keys)
   - ECR repository URL
   - Cluster name
   - Environment domains

4. Rollback support:
   - Manual rollback via git revert