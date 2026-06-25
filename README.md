# iCOUNTER API — CI/CD Pipeline on AWS + Kubernetes

Production-style CI/CD pipeline using Jenkins to deploy a containerized Node.js Express API to Amazon EKS, exposed via AWS ALB, with Karpenter-based autoscaling and scale-to-zero capability.

## Architecture

```
Developer ──> Git Push ──> Jenkins Pipeline
                              │
              ┌───────────────┼───────────────────────┐
              │               │                       │
          [Build]        [Unit Test]             [Docker Build]
              │               │                       │
              └───────────────┼───────────────────────┘
                              │
                      [Push to ECR]
                              │
                    [Deploy to EKS via Helm]
                              │
                    [Verify Deployment]

Internet ──> AWS ALB (Ingress) ──> K8s Service ──> Pods (:3000)
                                                     │
                                              [HPA scales pods]
                                                     │
                                          [Karpenter scales nodes]
```

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Application | Node.js + Express |
| Container | Docker (multi-stage build) |
| CI/CD | Jenkins (Declarative Pipeline) |
| Container Registry | AWS ECR |
| Kubernetes | Amazon EKS (v1.29) |
| Node Provisioning | Karpenter (spot + on-demand) |
| System Pods | AWS Fargate |
| Load Balancer | AWS ALB (via AWS Load Balancer Controller) |
| Pod Autoscaling | HPA (CPU + Memory) |
| Infrastructure | Terraform |

## Prerequisites

- AWS CLI v2 configured with credentials
- Terraform >= 1.5
- kubectl
- Helm v3
- Docker
- Node.js >= 20 (for local development)
- Jenkins with plugins: Pipeline, Docker Pipeline, AWS Credentials, Kubernetes CLI

## Project Structure

```
├── app/                    # Node.js Express API
│   ├── src/app.js          # Express app (routes: /health, /api, /api/info)
│   ├── src/index.js        # Server entry point
│   └── tests/app.test.js   # Jest unit tests
├── Dockerfile              # Multi-stage Docker build
├── Jenkinsfile             # CI/CD pipeline (7 stages)
├── helm/icounter-api/      # Helm chart
│   ├── templates/          # K8s manifests (deployment, service, ingress, hpa)
│   ├── values.yaml         # Default values
│   ├── values-staging.yaml
│   └── values-production.yaml
└── terraform/              # AWS infrastructure
    ├── main.tf             # Module composition
    └── modules/            # VPC, IAM, EKS, ECR, Karpenter, ALB Controller
```

---

## 1. Infrastructure Setup (Terraform)

### Provision AWS Infrastructure

```bash
cd terraform

# Initialize Terraform
terraform init

# Preview changes
terraform plan

# Apply (creates VPC, EKS, ECR, Karpenter, ALB Controller)
terraform apply
```

### Configure kubectl

```bash
aws eks update-kubeconfig --name icounter-cluster --region ap-south-1
```

### Infrastructure Components

| Resource | Details |
|----------|---------|
| VPC | 10.0.0.0/16, 2 AZs, single NAT gateway |
| EKS | v1.29, Fargate profiles for kube-system + karpenter |
| ECR | `icounter-api` repository with lifecycle policy |
| Karpenter | Spot-preferred, scale-to-zero, consolidation enabled |
| ALB Controller | Deployed via Helm, IRSA authentication |
| Metrics Server | Enables HPA pod autoscaling |

### Cost Estimate

| Component | Monthly Cost |
|-----------|-------------|
| EKS Control Plane | ~$73 |
| Fargate (system pods) | ~$29 |
| NAT Gateway | ~$32 |
| **Idle Total** | **~$134** |
| Spot nodes (when active) | ~$5-15 (60-90% off on-demand) |
| ALB (when active) | ~$16 |

### Teardown

```bash
# Remove application first
helm uninstall icounter-api -n icounter

# Destroy infrastructure
cd terraform
terraform destroy
```

> **Warning**: EKS control plane costs ~$0.10/hr ($73/month) even idle. Always run `terraform destroy` when done.

---

## 2. Pipeline Flow (Step-by-Step)

The Jenkins pipeline (`Jenkinsfile`) has 7 stages:

### Stage 1: Checkout
Pulls the latest source code from `https://github.com/devketsops/icounter-api.git`.

### Stage 2: Build
```bash
cd app && npm ci
```
Installs Node.js dependencies with a clean install for reproducibility.

### Stage 3: Unit Test
```bash
cd app && npm test
```
Runs Jest test suite with coverage. Tests verify:
- `GET /health` returns 200 with `{ status: "healthy" }`
- `GET /api` returns 200 with welcome message
- `GET /api/info` returns service info with uptime
- Unknown routes return 404

Can be skipped via `SKIP_TESTS` parameter.

### Stage 4: Docker Build
```bash
docker build -t <ECR_URL>/icounter-api:<BUILD_NUMBER> \
             -t <ECR_URL>/icounter-api:latest .
```
Multi-stage build: installs production deps, copies source, runs as non-root user. Final image is ~50MB (node:20-alpine).

### Stage 5: Push to ECR
```bash
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin <ECR_URL>
docker push <ECR_URL>/icounter-api:<BUILD_NUMBER>
docker push <ECR_URL>/icounter-api:latest
```
Authenticates with ECR and pushes both the versioned and latest tags.

### Stage 6: Deploy to Kubernetes
```bash
helm upgrade --install icounter-api ./helm/icounter-api \
    --namespace icounter \
    -f helm/icounter-api/values-<ENVIRONMENT>.yaml \
    --set image.repository=<ECR_URL>/icounter-api \
    --set image.tag=<BUILD_NUMBER> \
    --wait --timeout 300s
```
- Creates namespace if it doesn't exist
- Uses environment-specific values file (staging/production)
- `--wait` ensures pipeline reports success only after pods are healthy
- Karpenter automatically provisions a spot node when pods are scheduled

### Stage 7: Verify Deployment
```bash
kubectl rollout status deployment/icounter-api -n icounter --timeout=120s
kubectl get pods -n icounter -l app.kubernetes.io/name=icounter-api
kubectl get ingress -n icounter
```
Confirms rollout succeeded, lists running pods, and shows ALB endpoint.

### Pipeline Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| ENVIRONMENT | staging | Target environment (staging/production) |
| SKIP_TESTS | false | Skip unit test stage |
| DRY_RUN | false | Helm dry-run only (no actual deploy) |

---

## 3. Deployment Strategy + Rollback

### Strategy: Rolling Update

Configured in the Helm chart with zero-downtime guarantees:

```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1        # Create at most 1 extra pod during update
    maxUnavailable: 0  # Never kill a pod before its replacement is ready
```

**How it works:**
1. `helm upgrade` creates a new ReplicaSet with the updated image tag
2. Kubernetes creates 1 new pod (`maxSurge: 1`)
3. New pod starts and must pass the readiness probe on `/health`
4. Once ready, one old pod is terminated
5. Process repeats until all pods are running the new version
6. Zero downtime throughout — old pods serve traffic until new pods are ready

### Rollback

**Automatic (on pipeline failure):**
The Jenkinsfile `post.failure` block automatically rolls back:
```bash
helm rollback icounter-api 0 --namespace icounter
```
Revision `0` means "previous revision" — restores the last known-good deployment.

**Manual rollback:**
```bash
# View release history
helm history icounter-api --namespace icounter

# Rollback to specific revision
helm rollback icounter-api <REVISION> --namespace icounter

# Or use kubectl directly
kubectl rollout undo deployment/icounter-api -n icounter
```

---

## 4. AWS Integration

### ECR (Elastic Container Registry)
- Private registry: `<ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/icounter-api`
- Image scanning enabled on push
- Lifecycle policy: retains last 10 untagged images to prevent storage bloat
- Jenkins authenticates via `aws ecr get-login-password`

### EKS (Elastic Kubernetes Service)
- Managed Kubernetes v1.29 cluster
- Fargate profiles for system components (no EC2 nodes needed for cluster operations)
- OIDC provider for IRSA (IAM Roles for Service Accounts)
- EKS add-ons: vpc-cni, kube-proxy, CoreDNS (Fargate-compatible)

### ALB (Application Load Balancer)
- Provisioned automatically by AWS Load Balancer Controller from Kubernetes Ingress resources
- Internet-facing, HTTP on port 80
- Target type: IP (routes directly to pod IPs, no NodePort needed)
- Health checks on `/health` every 15 seconds

---

## 5. ALB + Kubernetes Traffic Flow

```
Client Request (HTTP)
    │
    ▼
AWS ALB (internet-facing)
    │  ── provisioned by AWS Load Balancer Controller
    │  ── from Kubernetes Ingress resource
    │
    ▼
Target Group (IP mode)
    │  ── targets are pod IPs directly (not node IPs)
    │  ── health checks: GET /health every 15s
    │  ── unhealthy threshold: 3 failures → pod removed from rotation
    │
    ▼
Kubernetes Pod (port 3000)
    │  ── Express.js handles request
    │  ── routes: /health, /api, /api/info
    │
    ▼
HTTP Response → Client
```

**Key details:**
- ALB uses **IP target type** — traffic goes directly to pod IPs, bypassing kube-proxy for lower latency
- ALB health checks are independent of Kubernetes probes — both must pass for traffic to reach a pod
- If a pod fails the ALB health check (3 consecutive failures), it's removed from the target group
- When new pods are created (scale-up or rolling update), they're added to the target group after passing health checks

---

## 6. Autoscaling

### Two-Level Autoscaling

```
                     ┌─────────────────────┐
                     │   HPA (Pod Level)   │
                     │                     │
                     │  CPU > 60%  ──────> Scale up pods
                     │  Memory > 75% ────> Scale up pods
                     │  Stabilize 300s ──> Scale down pods
                     └─────────┬───────────┘
                               │
                               │ More pods need more nodes
                               │
                     ┌─────────▼───────────┐
                     │ Karpenter (Node)    │
                     │                     │
                     │  Pending pods ─────> Provision spot node
                     │  Empty nodes ─────> Terminate in 30s
                     │  Underutilized ───> Consolidate & replace
                     └─────────────────────┘
```

### HPA (Horizontal Pod Autoscaler)

| Setting | Staging | Production |
|---------|---------|------------|
| Min replicas | 2 | 3 |
| Max replicas | 4 | 10 |
| CPU target | 60% | 60% |
| Memory target | 75% | 75% |
| Scale-down window | 300s | 300s |

HPA monitors pod CPU and memory utilization via the metrics-server. When average utilization exceeds the target, new pods are scheduled. The 300-second stabilization window prevents flapping (rapid scale-up/scale-down cycles).

### Karpenter (Node Autoscaler)

**Instance Selection:**
- Preferred: Spot instances (60-90% cheaper than on-demand)
- Fallback: On-demand instances
- Instance types: t3.small, t3.medium, t3a.small, t3a.medium, m5.large, m5a.large
- Diverse families ensure spot availability across at least one type

**Scale-to-Zero:**
When all application pods are removed (e.g., `helm uninstall`), Karpenter terminates all nodes within 30 seconds. System pods continue running on Fargate (no EC2 cost).

**Consolidation:**
Karpenter continuously monitors node utilization. If pods can be packed onto fewer nodes, it cordons the underutilized node, reschedules pods, and terminates it. This keeps compute costs minimal.

**Spot Interruption Handling:**
An SQS queue receives EC2 spot interruption warnings via EventBridge. Karpenter drains the affected node and provisions a replacement before the interruption occurs.

**Safety Limits:**
- Max 10 CPU cores across all Karpenter-managed nodes
- Max 40Gi memory across all Karpenter-managed nodes
- Node expiry: 30 days (forces rotation for security patching)

---

## 7. Secrets & Configuration Management

### Current Implementation

**ConfigMap** (non-sensitive, environment-specific):
| Key | Staging | Production |
|-----|---------|------------|
| NODE_ENV | staging | production |
| LOG_LEVEL | debug | warn |
| APP_VERSION | Set by Jenkins | Set by Jenkins |

**Kubernetes Secrets** (sensitive, mocked for this assignment):
| Key | Value |
|-----|-------|
| DB_PASSWORD | mocked-password (base64 encoded) |
| API_KEY | mocked-api-key (base64 encoded) |

Both are injected into pods via `envFrom` in the Deployment template. Checksum annotations on the pod template ensure pods restart when config/secrets change.

### Production Recommendation

For production workloads, use **AWS Secrets Manager + External Secrets Operator**:

```
AWS Secrets Manager ──> External Secrets Operator ──> K8s Secret ──> Pod
```

This approach:
- Stores secrets outside the cluster with encryption at rest
- Supports automatic rotation
- Provides audit logging via CloudTrail
- Eliminates base64-encoded secrets from Git/Helm values

---

## Local Development

```bash
# Install dependencies
cd app && npm install

# Run tests
npm test

# Start the API locally
npm start
# API available at http://localhost:3000

# Build Docker image
docker build -t icounter-api .

# Run container
docker run -p 3000:3000 icounter-api

# Test
curl http://localhost:3000/health
curl http://localhost:3000/api
```
