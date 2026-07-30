你是aws架构师和devops。我需要做一个demo，关于各种环境的发布。我需要3个环境。dev, staging, prod. 
4个分支：feature, develop, staging, prodution。
当feature被合并到develop，更新会被发布到dev环境。
当develop被合并到staging，更新会被发布到staging环境。
当staging被合并到production上，更新会被发布到prod环境。
我需要一个简单的app。就是在EKS上装个nginx pod，然后再发布一个简单的angular前端，让外网可以看到网页。不需要后端。


feature/* → develop (PR合并) → 触发Dev环境部署
develop → staging (PR合并) → 触发Staging环境部署  
staging → main/production (PR合并) → 触发Prod环境部署




Ingress Controller: AWS Load Balancer Controller (支持ALB)
DNS: Route53 (或使用临时域名)
容器镜像:
Nginx (作为反向代理)
Angular应用 (编译后的静态文件)
CI/CD: GitHub Actions





Dev: dev.microservice_2.ekslab.xyz
Staging: staging.microservice_2.ekslab.xyz
Prod: microservice_2.ekslab.xyz





microservice_2/
├── .github/
│   ├── workflows/
│   │   └── deploy.yml
│   └── PULL_REQUEST_TEMPLATE.md
├── kubernetes/
│   ├── base/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   └── overlays/
│       ├── dev/
│       ├── staging/
│       └── prod/
├── frontend/
│   ├── src/
│   ├── Dockerfile
│   ├── nginx.conf
│   └── package.json
├── scripts/
│   └── verify-deployment.sh (simple health check only)
└── README.md


aws region is ca-central-1