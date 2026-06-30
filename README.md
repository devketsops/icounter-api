# iCOUNTER API — CI/CD Pipeline on AWS + Kubernetes

Production-style CI/CD pipeline using Jenkins and GitHub Actions to deploy a containerized Node.js Express API to Amazon EKS, exposed via AWS ALB, with Karpenter-based node provisioning (on-demand) and scale-to-zero capability.

## Architecture

```
                       ┌──────────────────┐
Developer ──> Git Push │  Jenkins         │
                       │  GitHub Actions  │
                       └────────┬─────────┘
                                │
                ┌───────────────┼───────────────────────┐
                │               │                       │
            [Build]        [Unit Test]             [Docker Build]
                │               │                       │
                └───────────────┼───────────────────────┘
                                │
                        [Push to ECR]
                                │
                     [Security Scan (ECR/Inspector)]
                                │
                    [Production Gate (if production)]
                                │
                      [Deploy to EKS via Helm]
                                │
                   [Verify Deployment + Health Check]

Internet ──> AWS ALB (Ingress) ──> NetworkPolicy ──> K8s Service ──> Pods (:3000)
                                                                       │
                                                                [HPA scales pods]
                                                                       │
                                                            [Karpenter scales nodes]
```

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Application | Node.js 22 + Express 5 |
| Container | Docker (multi-stage build, node:22-alpine) |
| CI/CD | Jenkins (Declarative Pipeline) + GitHub Actions |
| Container Registry | AWS ECR |
| Kubernetes | Amazon EKS (v1.35) |
| Node Provisioning | Karpenter (on-demand) |
| System Pods | EKS Managed Node Group (Core Infrastructure Tier) |
| Load Balancer | AWS ALB (via AWS Load Balancer Controller) |
| Pod Autoscaling | HPA (CPU + Memory) |
| Security | NetworkPolicy, SecurityContext, PodDisruptionBudget |
| Image Scanning | AWS ECR / Inspector (scan on push) |
| Infrastructure | Terraform |

## Prerequisites

- AWS CLI v2 configured with credentials
- Terraform >= 1.15
- kubectl
- Helm v3
- Docker
- Node.js >= 22 (for local development)
- Jenkins with plugins: Pipeline, Docker Pipeline, AWS Credentials, Kubernetes CLI

## Project Structure

```
├── app/                    # Node.js Express API
│   ├── src/app.js          # Express app (routes: /health, /api, /api/info)
│   ├── src/index.js        # Server entry point
│   └── tests/app.test.js   # Jest unit tests
├── .github/workflows/
│   └── deploy.yml          # GitHub Actions CI/CD workflow
├── Dockerfile              # Multi-stage Docker build
├── Jenkinsfile             # Jenkins CI/CD pipeline (8 stages)
├── helm/
│   ├── icounter-api/       # Application Helm chart
│   │   ├── templates/      # K8s manifests (deployment, service, ingress, hpa,
│   │   │                   #   networkpolicy, serviceaccount, pdb)
│   │   ├── values.yaml     # Default values
│   │   ├── values-staging.yaml
│   │   └── values-production.yaml
│   ├── alb-controller/     # ALB Controller Helm chart (wraps official chart)
│   │   ├── Chart.yaml      # Official aws-load-balancer-controller as dependency
│   │   └── values.yaml     # Cluster name, IRSA annotation, region, VPC
│   ├── metrics-server/     # Metrics Server Helm chart (required for HPA)
│   │   ├── Chart.yaml      # Official metrics-server as dependency
│   │   └── values.yaml     # kubelet-insecure-tls config
│   ├── karpenter/          # Karpenter Helm chart (wraps official chart + CRDs)
│   │   ├── Chart.yaml      # Official karpenter chart as dependency
│   │   ├── templates/      # NodePool and EC2NodeClass CRDs
│   │   └── values.yaml     # Default values
│   └── external-secrets/   # External Secrets Operator (syncs AWS SM → K8s Secrets)
│       ├── Chart.yaml      # Official external-secrets as dependency
│       ├── templates/      # ClusterSecretStore CR
│       └── values.yaml     # IRSA annotation, tolerations, region
└── terraform/              # AWS infrastructure (pure AWS resources, no Helm/K8s)
    ├── vpc.tf              # VPC, subnets, NAT, route tables
    ├── iam.tf              # All IAM roles (EKS, Core Node, Karpenter, ALB, ESO)
    ├── eks.tf              # EKS cluster, core node group, add-ons, OIDC
    ├── ecr.tf              # ECR repository + lifecycle policy
    ├── secrets.tf          # AWS Secrets Manager secrets (DB password, API key)
    ├── providers.tf        # AWS and TLS providers
    ├── variables.tf        # Input variables
    ├── outputs.tf          # Terraform outputs
    └── terraform.tfvars    # Variable values
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

# Apply (single stage — creates VPC, EKS, ECR, IAM roles)
terraform apply
```

### Configure kubectl

```bash
aws eks update-kubeconfig --name icounter-cluster --region ap-south-1
```

### Install Cluster Components (Helm)

After Terraform creates the AWS infrastructure, install the Kubernetes components via Helm:

```bash
# Add required Helm repositories (one-time setup)
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server
helm repo add eks https://aws.github.io/eks-charts
aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws
helm repo update

# Get values from Terraform output
EKS_ENDPOINT=$(terraform output -raw eks_cluster_endpoint)
VPC_ID=$(terraform output -raw vpc_id)
ALB_ROLE_ARN=$(terraform output -raw alb_controller_role_arn)
KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)

# 1. Install Metrics Server (required for HPA)
helm dependency build ../helm/metrics-server/
helm upgrade --install metrics-server ../helm/metrics-server/ -n kube-system --wait

# 2. Install ALB Controller
helm dependency build ../helm/alb-controller/
helm upgrade --install alb-controller ../helm/alb-controller/ \
  -n kube-system \
  -f ../helm/alb-controller/values-staging.yaml \
  --set "aws-load-balancer-controller.vpcId=$VPC_ID" \
  --set "aws-load-balancer-controller.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ALB_ROLE_ARN" \
  --wait

# 3. Install Karpenter
helm dependency build ../helm/karpenter/
helm upgrade --install karpenter ../helm/karpenter/ \
  -n kube-system \
  -f ../helm/karpenter/values-staging.yaml \
  --set karpenter.settings.clusterEndpoint=$EKS_ENDPOINT \
  --set "karpenter.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KARPENTER_ROLE_ARN" \
  --wait

# 4. Install External Secrets Operator
ESO_ROLE_ARN=$(terraform output -raw external_secrets_role_arn)
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm dependency build ../helm/external-secrets/
helm upgrade --install external-secrets ../helm/external-secrets/ \
  -n kube-system \
  --set "external-secrets.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ESO_ROLE_ARN" \
  --wait
```

### Infrastructure Components

| Resource | Details |
|----------|---------|
| VPC | 10.0.0.0/16, 2 AZs, single NAT gateway |
| EKS | v1.35, managed node group for core infrastructure |
| ECR | `icounter-api` repository with lifecycle policy |
| Secrets Manager | `icounter/db-password` and `icounter/api-key` secrets |
| Karpenter IAM | Controller IRSA role + node role (Terraform), controller + CRDs (Helm) |
| ALB Controller IAM | IRSA role (Terraform), controller deployment (Helm) |
| External Secrets IAM | IRSA role (Terraform), operator + ClusterSecretStore (Helm) |
| Metrics Server | Deployed via Helm, enables HPA pod autoscaling |

### Terraform Code Breakdown

#### `providers.tf` — Provider Configuration

- **AWS Provider (~> 6.0)** — the only provider needed. Creates all AWS resources, configured for `ap-south-1` (Mumbai)
- AWS handles EKS OIDC certificate verification internally using its trusted CA library, so no TLS provider is needed

#### `variables.tf` + `terraform.tfvars` — Input Variables

`variables.tf` declares inputs with defaults. `terraform.tfvars` overrides them — lets you change environments without touching the code.

| Variable | Default | Purpose |
|----------|---------|---------|
| `aws_region` | `ap-south-1` | Which AWS datacenter region to use |
| `project_name` | `icounter` | Prefix added to every resource name (e.g. `icounter-cluster`, `icounter-vpc`) |
| `environment` | `staging` | Tag for environment identification |
| `vpc_cidr` | `10.0.0.0/16` | VPC address space — 65,536 IP addresses |
| `eks_cluster_version` | `1.35` | Kubernetes version for EKS |
| `core_node_instance_types` | `["t3.medium"]` | EC2 instance size for core infrastructure nodes (2 vCPU, 4 GB RAM) |
| `core_node_desired_size` | `2` | How many core nodes to run normally |
| `core_node_min_size` | `2` | Never go below this many core nodes |
| `core_node_max_size` | `3` | Never exceed this many core nodes |

#### `backend.tf` — State Storage

Uses an S3 remote backend for state management:

- **S3 bucket** (`icounter-terraform-state`) — stores state remotely so a team can share it, with versioning and encryption
- **S3-native locking** (`use_lockfile = true`) — uses S3 conditional writes to prevent two people from running `terraform apply` at the same time. No DynamoDB table required (requires Terraform >= 1.10)
- **encrypt = true** — state contains sensitive info (ARNs, endpoints), so encrypt it at rest

To migrate from local to remote state:
```bash
terraform init -migrate-state
```

#### `vpc.tf` — Networking

Everything runs inside this network. Think of it as building roads, highways, and walls before putting buildings on them.

```
VPC (10.0.0.0/16)
├── Public Subnets (internet-facing)
│   ├── 10.0.1.0/24 in AZ-1 (ap-south-1a)
│   └── 10.0.2.0/24 in AZ-2 (ap-south-1b)
│
├── Private Subnets (internal, no public IPs)
│   ├── 10.0.10.0/24 in AZ-1
│   └── 10.0.11.0/24 in AZ-2
│
├── Internet Gateway ──> Public subnets (direct internet access)
├── NAT Gateway ──> Private subnets (outbound-only, like a one-way door)
│   └── Elastic IP (static public IP for NAT)
│
├── Public Route Table:  0.0.0.0/0 → Internet Gateway
└── Private Route Table: 0.0.0.0/0 → NAT Gateway
```

**Resource-by-resource:**

| Resource | What it does in simple words |
|----------|-----|
| `data "aws_availability_zones"` | Asks AWS "which datacenters are available?" then picks the first 2 for high availability |
| `aws_vpc.main` | Creates the isolated network. DNS is enabled so pods can resolve hostnames |
| `aws_subnet.public[0..1]` | Two public subnets with auto-assigned public IPs. The `kubernetes.io/role/elb` tag tells the ALB controller "put internet-facing load balancers here" |
| `aws_subnet.private[0..1]` | Two private subnets — hidden from the internet. The `karpenter.sh/discovery` tag lets Karpenter find these subnets when launching worker nodes. The `kubernetes.io/role/internal-elb` tag is for internal load balancers |
| `aws_internet_gateway.main` | The door between your VPC and the internet — without it, nothing can reach the outside world |
| `aws_eip.nat` | A fixed public IP address that gets attached to the NAT Gateway |
| `aws_nat_gateway.main` | Sits in the first public subnet. Lets private-subnet resources (pods, nodes) reach the internet to pull images and call APIs, but the internet cannot reach them directly |
| `aws_route_table.public` | Routing rule: "Any traffic going outside the VPC goes through the Internet Gateway" |
| `aws_route_table.private` | Routing rule: "Any outbound traffic goes through the NAT Gateway" |
| `aws_route_table_association.public/private` | Links each subnet to its route table — without these, the subnets wouldn't know which routing rules to follow |

- Subnets are auto-carved from the VPC CIDR using `cidrsubnet()` function
- Single NAT Gateway keeps cost low for staging (production would use one per AZ)

#### `eks.tf` — EKS Cluster, Core Nodes & Add-ons

```
EKS Cluster (icounter-cluster, v1.35)
├── VPC Config: all 4 subnets, public + private endpoint access
├── Auth: API mode (access managed entirely through AWS API)
│
├── Access Entries (who can access the cluster)
│   ├── Karpenter node role (EC2_LINUX) — lets Karpenter-launched nodes join
│   ├── Core node role (EC2_LINUX) — lets core infra nodes join
│   └── Admin (Terraform IAM user) — full cluster admin access
│
├── Core Node Group (always-on infrastructure tier)
│   ├── 2x t3.medium across 2 AZs (private subnets)
│   ├── Taint: CriticalAddonsOnly=true:NoSchedule
│   ├── Label: node-role=core-infra
│   └── Runs: Karpenter, ALB Controller, Metrics Server, CoreDNS
│
├── EKS Add-ons (managed by AWS)
│   ├── vpc-cni — assigns VPC IPs to pods + enforces NetworkPolicy (DaemonSet on ALL nodes)
│   ├── kube-proxy — in-cluster service routing (DaemonSet on ALL nodes)
│   └── coredns — DNS resolution (pinned to core nodes via toleration + nodeSelector)
│
├── OIDC Provider — enables IRSA (IAM Roles for Service Accounts)
│
└── Cluster SG Tag — karpenter.sh/discovery for Karpenter
```

**Resource-by-resource:**

| Resource | What it does in simple words |
|----------|-----|
| `aws_eks_cluster.main` | Creates the EKS control plane — the Kubernetes API server, etcd, scheduler. AWS fully manages this. `endpoint_private_access = true` means pods can reach the API. `endpoint_public_access = true` means you can run kubectl from your laptop. `authentication_mode = "API"` means cluster access is managed through access entries below, not the legacy aws-auth ConfigMap |
| `aws_eks_access_entry.karpenter_node` | "EC2 instances using the Karpenter node role are allowed to join this cluster." When Karpenter launches a new instance, this is how it registers with the cluster |
| `aws_eks_access_entry.admin` | "The IAM identity running Terraform can access this cluster" |
| `aws_eks_access_policy_association.admin` | "Give that admin identity full cluster admin permissions across all namespaces" |
| `aws_eks_access_entry.core_node` | "EC2 instances using the core node role are allowed to join this cluster" |
| `aws_eks_node_group.core` | The **Core Infrastructure Tier** — 2 always-on EC2 instances managed by EKS. The taint `CriticalAddonsOnly=true:NoSchedule` means "do NOT schedule any pod here UNLESS that pod explicitly tolerates this taint." Your application pods don't have this toleration, so they can never land here. Only system components (Karpenter, ALB Controller, Metrics Server, CoreDNS) have the matching toleration. The `node-role=core-infra` label lets those system components target these nodes via `nodeSelector`. `max_unavailable = 1` during updates ensures at least 1 core node is always running |
| `aws_eks_addon.vpc_cni` | VPC CNI plugin — assigns real VPC IP addresses to pods so they can communicate directly with AWS resources. Configured with `enableNetworkPolicy = true` to enforce Kubernetes NetworkPolicy resources. Runs as a DaemonSet on every node (both core and Karpenter). DaemonSets automatically tolerate all taints |
| `aws_eks_addon.kube_proxy` | Maintains network rules on each node that make Kubernetes Services work (traffic to Service IP gets forwarded to the right pods). Also a DaemonSet on every node |
| `aws_eks_addon.coredns` | Cluster DNS server — resolves names like `my-service.default.svc.cluster.local`. Unlike vpc-cni and kube-proxy, CoreDNS is a Deployment (not a DaemonSet), so it needs explicit tolerations and nodeSelector to run on the tainted core nodes |
| `aws_iam_openid_connect_provider.eks` | Registers the EKS OIDC endpoint with IAM. This enables **IRSA**: a Kubernetes pod proves its identity via OIDC, AWS verifies it, and issues temporary credentials for a specific IAM role. Only the designated ServiceAccount gets AWS access, not every pod |
| `aws_ec2_tag.cluster_sg_karpenter` | Tags the cluster's security group with `karpenter.sh/discovery` so Karpenter can find and attach it to new nodes |

#### `iam.tf` — IAM Roles & Policies (who is allowed to do what)

Each IAM role is like an ID badge that says "I am allowed to do these specific things." This file creates **6 roles**.

```
IAM Roles
├── EKS Cluster Role
│   └── Trust: eks.amazonaws.com → AmazonEKSClusterPolicy
│
├── Core Node Group Role (attached to core infrastructure EC2 instances)
│   ├── Trust: ec2.amazonaws.com
│   └── AmazonEKSWorkerNodePolicy, AmazonEKS_CNI_Policy
│       AmazonEC2ContainerRegistryReadOnly, AmazonSSMManagedInstanceCore
│
├── Karpenter Node Role (attached to Karpenter-launched EC2 instances)
│   ├── Trust: ec2.amazonaws.com
│   ├── AmazonEKSWorkerNodePolicy, AmazonEKS_CNI_Policy
│   ├── AmazonEC2ContainerRegistryReadOnly, AmazonSSMManagedInstanceCore
│   └── Instance Profile (required for Karpenter EC2 launch)
│
├── Karpenter Controller Role (IRSA — used by the Karpenter pod)
│   ├── Trust: OIDC federation (only kube-system:karpenter SA)
│   └── EC2 fleet management, IAM instance profiles, EKS, SSM, Pricing API
│
├── ALB Controller Role (IRSA — used by the ALB controller pod)
│   ├── Trust: OIDC federation (only kube-system:aws-load-balancer-controller SA)
│   └── ELB, EC2 security groups, ACM certificates, WAF/Shield
│
└── External Secrets Operator Role (IRSA — used by the ESO pod)
    ├── Trust: OIDC federation (only kube-system:external-secrets SA)
    └── secretsmanager:GetSecretValue, secretsmanager:DescribeSecret (scoped to app secrets)
```

**Resource-by-resource:**

| Resource | What it does in simple words |
|----------|-----|
| `data "aws_caller_identity"` | Looks up who is running Terraform (your IAM user/role ARN and account ID) |
| `aws_iam_role.eks_cluster` | The EKS service needs this role to manage the control plane. Only `eks.amazonaws.com` can use it. Has `AmazonEKSClusterPolicy` |
| `aws_iam_role.core_node` | The core infrastructure EC2 instances use this role. Only `ec2.amazonaws.com` can use it. 4 policies: register as EKS node, manage pod networking, pull images from ECR, allow SSM access for troubleshooting |
| `aws_iam_role.karpenter_node` | Same 4 policies as core node, but for EC2 instances that Karpenter dynamically launches. Kept separate so changes to one don't break the other. Also has an **instance profile** because Karpenter creates its own launch templates (the managed node group handles instance profiles internally) |
| `aws_iam_role.karpenter_controller` | The Karpenter pod assumes this via **IRSA**. Only the `kube-system:karpenter` ServiceAccount can use it (enforced by OIDC conditions). Permissions: launch/terminate EC2 instances, manage instance profiles, read cluster info, look up AMI IDs via SSM, query instance pricing to pick the cheapest option |
| `aws_iam_role.alb_controller` | The ALB controller pod assumes this via **IRSA**. Only `kube-system:aws-load-balancer-controller` can use it. Permissions: create/modify/delete ALBs, manage security groups, register pod IPs as targets, manage TLS certificates, optionally attach WAF/Shield. Condition blocks ensure it only touches resources it created (tagged with `elbv2.k8s.aws/cluster`) |
| `aws_iam_role.external_secrets` | The External Secrets Operator pod assumes this via **IRSA**. Only `kube-system:external-secrets` can use it. Permissions: read secrets from AWS Secrets Manager (`GetSecretValue`, `DescribeSecret`), scoped to only the `icounter/db-password` and `icounter/api-key` secrets |

- **IRSA** restricts AWS permissions to specific K8s service accounts via OIDC conditions — only the designated pod gets AWS access, not every pod in the cluster
- **Karpenter has two roles:** the controller role (to launch/terminate instances) and the node role (for launched instances to join the cluster and pull images)
- **Core node role is separate from Karpenter node role** for blast-radius isolation — if you change one, the other is unaffected

#### `ecr.tf` — Container Registry

| Resource | What it does in simple words |
|----------|-----|
| `aws_ecr_repository.main` | Creates a private Docker registry named `icounter-api`. `scan_on_push = true` means every pushed image gets scanned for security vulnerabilities. `image_tag_mutability = IMMUTABLE` prevents overwriting existing tags (supply-chain safety). `force_delete` is controlled by a variable (default `false` for production safety) |
| `aws_ecr_lifecycle_policy.main` | Cleanup rule: when there are more than 10 untagged images, delete the oldest ones. Prevents storage costs from growing forever |

#### `secrets.tf` — AWS Secrets Manager

| Resource | What it does in simple words |
|----------|-----|
| `aws_secretsmanager_secret.db_password` | Creates a secret named `icounter/db-password` in AWS Secrets Manager. Stores the database password outside the cluster with encryption at rest |
| `aws_secretsmanager_secret.api_key` | Creates a secret named `icounter/api-key`. Stores the API key with the same protections |
| `aws_secretsmanager_secret_version.*` | Sets the initial value for each secret as JSON (e.g. `{"password": "..."}` and `{"key": "..."}`). Values are passed via Terraform variables marked `sensitive` — never stored in Git |

The External Secrets Operator reads these secrets and syncs them into Kubernetes Secrets, which pods consume via `envFrom`.

#### `outputs.tf` — Exported Values

These are printed after `terraform apply` and consumed by Helm charts, kubectl, and CI/CD.

| Output | What you use it for |
|--------|-----|
| `eks_cluster_endpoint` | The Kubernetes API server URL — passed to Karpenter Helm install |
| `eks_cluster_name` | Used in kubectl config and Helm chart references |
| `ecr_repository_url` | The full URL for `docker push` (e.g. `123456789.dkr.ecr.ap-south-1.amazonaws.com/icounter-api`) |
| `vpc_id` | Needed by the ALB controller Helm chart to know which VPC to create load balancers in |
| `alb_controller_role_arn` | Passed to ALB controller Helm chart for IRSA ServiceAccount annotation |
| `karpenter_controller_role_arn` | Passed to Karpenter Helm chart for IRSA ServiceAccount annotation |
| `external_secrets_role_arn` | Passed to External Secrets Operator Helm chart for IRSA ServiceAccount annotation |
| `core_node_role_arn` | Core node group's IAM role ARN — useful for debugging and auditing |
| `kubeconfig_command` | Ready-to-run command to configure kubectl on your machine |

#### How Terraform Files Connect

```
terraform.tfvars (inputs)
    │
    ▼
vpc.tf ─────────────> eks.tf ──────────────> iam.tf
(network foundation)  (cluster + nodes       (roles + policies)
                       + OIDC)                    │
    │                     │                       ▼
    │                     │                  IRSA binds K8s SAs
    │                     │                  to IAM roles via OIDC
    │                     │
    ▼                     ▼
ecr.tf               outputs.tf ──> Helm installs use these values
(image storage)      │
                     │
secrets.tf           │
(AWS Secrets Mgr)    │
```

**Deployment flow after `terraform apply`:**

```
1. VPC, subnets, IGW, NAT created
2. IAM roles created (cluster, core node, karpenter node, karpenter controller, ALB controller, ESO)
3. EKS cluster created
4. Access entries registered (core nodes, karpenter nodes, admin)
5. OIDC provider created (enables IRSA)
6. Core node group launches 2x t3.medium (tainted, labeled)
7. EKS addons install (vpc-cni, kube-proxy, CoreDNS → on core nodes)
8. ECR repository created
9. Secrets Manager secrets created (icounter/db-password, icounter/api-key)
        │
        ▼
Helm installs (using Terraform outputs)
├── Karpenter → schedules on core nodes (has toleration + nodeSelector)
├── ALB Controller → schedules on core nodes
├── Metrics Server → schedules on core nodes
└── External Secrets Operator → schedules on core nodes, creates ClusterSecretStore
        │
        ▼
App deployment (via Jenkins or GitHub Actions)
├── Image pushed to ECR
├── Helm deploys pods + ExternalSecret CR
├── ESO syncs Secrets Manager → K8s Secret
├── Pods start with secrets from envFrom
├── Karpenter sees pending pods → launches new EC2 (application nodes)
└── ALB Controller creates load balancer → traffic flows
```

### Teardown

```bash
# Remove application first
helm uninstall icounter-api -n icounter

# Remove cluster components
helm uninstall external-secrets -n kube-system
helm uninstall karpenter -n kube-system
helm uninstall alb-controller -n kube-system
helm uninstall metrics-server -n kube-system

# Destroy infrastructure
cd terraform
terraform destroy
```

> **Warning**: EKS control plane costs ~$0.10/hr ($73/month) even idle. Always run `terraform destroy` when done.

---

## 2. Pipeline Flow (Step-by-Step)

The Jenkins pipeline (`Jenkinsfile`) has 8 stages with built-in security scanning, production gating, and credential management:

### Pipeline Options

- **Timestamps** on all console output
- **45-minute timeout** to prevent runaway builds
- **Concurrent build prevention** — only one build runs at a time
- **Build log rotation** — keeps last 20 builds

### Stage 1: Checkout
Pulls the latest source code and captures a short git SHA. Image tags use `${BUILD_NUMBER}-${GIT_SHA_SHORT}` format for commit traceability.

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
docker pull <ECR_URL>/icounter-api:latest  # cache layer
docker build --cache-from <ECR_URL>/icounter-api:latest \
             -t <ECR_URL>/icounter-api:<IMAGE_TAG> \
             -t <ECR_URL>/icounter-api:latest .
```
Multi-stage build: installs production deps, copies source, runs as non-root user. Final image is ~50MB (node:22-alpine). OS packages are patched at build time via `apk upgrade`. Pulls the latest image first and uses `--cache-from` for faster builds.

### Stage 5: Push to ECR
Authenticates with ECR via `withCredentials` and pushes both the versioned and latest tags. All AWS CLI calls are wrapped in explicit credential bindings.

### Stage 6: Security Scan (AWS ECR / Inspector)
```bash
aws ecr wait image-scan-complete --repository-name icounter-api --image-id imageTag=<IMAGE_TAG>
aws ecr describe-image-scan-findings --query 'imageScanFindings.findingSeverityCounts.CRITICAL'
```
Leverages ECR's `scan_on_push` (backed by AWS Inspector). Waits for the scan to complete, then checks for CRITICAL vulnerabilities. If any are found, the build fails and deployment is blocked.

### Stage 7: Deploy to Kubernetes
```bash
helm upgrade --install icounter-api ./helm/icounter-api \
    --namespace icounter \
    -f helm/icounter-api/values-<ENVIRONMENT>.yaml \
    --set image.repository=<ECR_URL>/icounter-api \
    --set image.tag=<IMAGE_TAG> \
    --wait --timeout 300s
```
- **Production gate**: production deploys require manual approval and can only run from the `main` branch
- Creates namespace if it doesn't exist
- Uses environment-specific values file (staging/production)
- Uses `--dry-run=client` when DRY_RUN parameter is enabled
- `--wait` ensures pipeline reports success only after pods are healthy
- Karpenter automatically provisions an on-demand node when pods are scheduled

### Stage 8: Verify Deployment
```bash
kubectl rollout status deployment/icounter-api -n icounter --timeout=120s
kubectl get pods -n icounter -l app=icounter-api
kubectl exec <pod> -- wget -qO- http://localhost:3000/health
```
Confirms rollout succeeded, lists running pods, shows ALB endpoint, and verifies the `/health` endpoint responds from inside a running pod.

### Pipeline Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| ENVIRONMENT | staging | Target environment (staging/production) |
| SKIP_TESTS | false | Skip unit test stage |
| DRY_RUN | false | Helm dry-run only (no actual deploy) |

### Jenkins Credentials Required

| Credential ID | Type | Purpose |
|---|---|---|
| `ecr-registry-url` | Secret Text | ECR registry URL |
| `aws-credentials` | AWS Credentials | AWS access key + secret for CLI calls |

---

## 3. GitHub Actions CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/deploy.yml`) provides an alternative CI/CD pipeline with branch-based environment selection and GitHub Environments for production approval gating.

### Pipeline Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        GitHub Actions Workflow                         │
│                     .github/workflows/deploy.yml                       │
└─────────────────────────────────────────────────────────────────────────┘

  ┌──────────────────┐
  │   Trigger Event   │
  └────────┬─────────┘
           │
           ├── Pull Request to main
           ├── Push to main
           └── Tag v* (e.g. v1.0.0)
           │
           ▼
  ┌──────────────────┐
  │  Build & Test     │  ◄── Runs on ALL triggers
  │                   │
  │  • Checkout code  │
  │  • Node.js 22     │
  │  • npm ci         │
  │  • npm test       │
  └────────┬─────────┘
           │
           ├── PR? ──────────────────────────────────── ✅ Done (no deploy)
           │
           ▼  (push to main or tag v*)
  ┌──────────────────┐
  │ Docker Build &    │
  │ Push to ECR       │
  │                   │
  │ • AWS credentials │
  │ • ECR login       │
  │ • Build amd64     │
  │ • Tag: run#-sha   │
  │ • Push to ECR     │
  └────────┬─────────┘
           │
           ▼
  ┌──────────────────┐
  │  Security Scan    │
  │                   │
  │ • ECR image scan  │
  │ • Wait for result │
  │ • Fail on         │
  │   CRITICAL vulns  │
  └────────┬─────────┘
           │
     ┌─────┴──────┐
     │            │
     ▼            ▼
  (main)       (tag v*)
     │            │
     ▼            ▼
  ┌────────┐  ┌────────────────┐
  │Staging │  │  Production    │
  │        │  │                │
  │No gate │  │ ⏸ Manual       │
  │        │  │   Approval     │
  │ values-│  │   Required     │
  │staging │  │                │
  │ .yaml  │  │ values-        │
  │        │  │ production.yaml│
  └───┬────┘  └──────┬─────────┘
      │              │
      ▼              ▼
  ┌──────────────────────────────┐
  │  Deploy to EKS (Helm)        │
  │                              │
  │  • aws eks update-kubeconfig │
  │  • Create namespace          │
  │  • helm upgrade --install    │
  │  • Verify rollout status     │
  │  • Health check via kubectl  │
  │  • Auto rollback on failure  │
  └──────────────────────────────┘
```

### Trigger Strategy

| Event | What runs |
|-------|-----------|
| **Pull request** to `main` | Build & Test only (no Docker build, no deploy) |
| **Push to `main`** | Full pipeline → deploy to **staging** |
| **Tag `v*`** (e.g. `v1.0.0`) | Full pipeline → deploy to **production** (approval required) |

### GitHub Environments

Two GitHub Environments are configured in the repository settings (Settings > Environments):

| Environment | Protection Rules | Purpose |
|-------------|-----------------|---------|
| `staging` | None | Auto-deploy on push to `main` |
| `production` | **Required reviewers** enabled | Manual approval gate before production deploy |

### Required GitHub Secrets

Configure these in Settings > Secrets and variables > Actions:

| Secret | Purpose |
|--------|---------|
| `AWS_ACCESS_KEY_ID` | AWS IAM access key for ECR, EKS, and CLI operations |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM secret key |

### How to Deploy

**Staging** — merge or push to `main`:
```bash
git push origin main
```

**Production** — create and push a version tag:
```bash
git tag v1.0.0
git push origin v1.0.0
```
A reviewer must approve the deployment in the GitHub Actions UI before it proceeds.

### Jobs Overview

| Job | Trigger | Depends On | Environment |
|-----|---------|-----------|-------------|
| `build-and-test` | All | — | — |
| `docker-build-push` | Push only | `build-and-test` | — |
| `security-scan` | Push only | `docker-build-push` | — |
| `deploy-staging` | Push to `main` | `docker-build-push`, `security-scan` | `staging` |
| `deploy-production` | Tag `v*` | `docker-build-push`, `security-scan` | `production` |

### Jenkins vs GitHub Actions Comparison

| Feature | Jenkins | GitHub Actions |
|---------|---------|---------------|
| Environment selection | Manual parameter choice | Branch-based (main → staging, tag → production) |
| Production approval | `input` step (admin/devops-leads) | GitHub Environment required reviewers |
| Credentials | Jenkins Credentials store | GitHub Secrets |
| Skip tests | `SKIP_TESTS` parameter | Not supported (tests always run) |
| Dry run | `DRY_RUN` parameter | Not supported (use PR for validation) |
| Security scan | ECR Inspector | ECR Inspector |
| Rollback | Post-failure block | `if: failure()` step |
| Build cache | `--cache-from` latest image | `--cache-from` latest image |

---

## 4. Deployment Strategy + Rollback

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
The Jenkinsfile `post.failure` block automatically rolls back (wrapped in AWS credentials for EKS exec-based kubeconfig):
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

## 5. AWS Integration

### ECR (Elastic Container Registry)
- Private registry: `<ACCOUNT_ID>.dkr.ecr.ap-south-1.amazonaws.com/icounter-api`
- Image scanning enabled on push
- Lifecycle policy: retains last 10 untagged images to prevent storage bloat
- Jenkins authenticates via `aws ecr get-login-password`

### EKS (Elastic Kubernetes Service)
- Managed Kubernetes v1.35 cluster
- Core infrastructure managed node group (2x t3.medium) with CriticalAddonsOnly taint for system components
- OIDC provider for IRSA (IAM Roles for Service Accounts)
- EKS add-ons: vpc-cni, kube-proxy, CoreDNS

### ALB (Application Load Balancer)
- Provisioned automatically by AWS Load Balancer Controller from Kubernetes Ingress resources
- Internet-facing, HTTP on port 80
- Target type: IP (routes directly to pod IPs, no NodePort needed)
- Health checks on `/health` every 15 seconds

---

## 6. ALB + Kubernetes Traffic Flow

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

## 7. Autoscaling

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

Karpenter is deployed via a dedicated Helm chart (`helm/karpenter/`) that wraps the official Karpenter OCI chart and includes NodePool and EC2NodeClass CRDs as templates.

#### EC2NodeClass Configuration

The EC2NodeClass defines what kind of EC2 instances Karpenter can launch:

| Setting | Value | Purpose |
|---------|-------|---------|
| Role | `icounter-karpenter-node-role` | IAM role attached to launched EC2 nodes (EKS worker, CNI, ECR, SSM permissions) |
| AMI Family | `al2023@latest` | Uses the latest Amazon Linux 2023 EKS-optimized AMI automatically |
| Subnet Discovery | Tag `karpenter.sh/discovery: icounter-cluster` | Launches nodes only in private subnets tagged for Karpenter |
| Security Group Discovery | Tag `karpenter.sh/discovery: icounter-cluster` | Uses the EKS cluster security group tagged in Terraform |
| Block Device | `/dev/xvda`, 20Gi (staging) / 50Gi (production), gp3, encrypted | Encrypted root volume for each node |

#### NodePool Configuration

The NodePool defines when, how many, and which nodes Karpenter provisions:

**Instance Requirements:**

| Constraint | Value | Purpose |
|-----------|-------|---------|
| Architecture | `amd64` | Only x86_64 instances (matches Docker image platform) |
| Capacity Type | `on-demand` (staging), `spot + on-demand` (production) | Cost optimization strategy per environment |
| Instance Types | `t3.small`, `t3.medium`, `t3a.small`, `t3a.medium`, `m5.large`, `m5a.large` | Karpenter picks the cheapest type that fits pending pod resource requests |

**Safety Limits (staging / production):**

| Limit | Staging | Production | Purpose |
|-------|---------|------------|---------|
| Max CPU | 10 cores | 100 cores | Total CPU across all Karpenter-managed nodes |
| Max Memory | 40Gi | 400Gi | Total memory across all Karpenter-managed nodes |

**Disruption & Lifecycle:**

| Setting | Value | Purpose |
|---------|-------|---------|
| Consolidation Policy | `WhenEmptyOrUnderutilized` | Removes nodes when empty or when pods can fit on fewer nodes |
| Consolidate After | `30s` | Aggressive cleanup for cost savings |
| Expire After | `720h` (30 days) | Forces node rotation for fresh AMIs and security patches |

#### Provisioning Flow

```
Pending pod (needs 100m CPU, 128Mi memory)
    │
    ▼
Karpenter detects the pending pod
    │
    ▼
NodePool: amd64, on-demand, pick from t3/t3a/m5 family
    │
    ▼
EC2NodeClass: use IAM role, private subnets, cluster SG, 20Gi disk
    │
    ▼
Karpenter picks cheapest fit (e.g. t3a.small at ~$0.0188/hr)
    │
    ▼
Node launches → pod schedules → app runs
    │
    ▼
All pods removed? → 30s later → node terminated (scale to zero)
```

**Scale-to-Zero:**
When all application pods are removed (e.g., `helm uninstall`), Karpenter terminates all application nodes within 30 seconds. The core infrastructure node group (2x t3.medium) remains running to host system components (Karpenter, ALB Controller, Metrics Server, CoreDNS).

**Consolidation:**
Karpenter continuously monitors node utilization. If pods can be packed onto fewer nodes, it cordons the underutilized node, reschedules pods, and terminates it. This keeps compute costs minimal.

---

## 8. Secrets & Configuration Management

### Configuration (ConfigMap)

Non-sensitive, environment-specific values injected via `envFrom`:

| Key | Staging | Production |
|-----|---------|------------|
| NODE_ENV | staging | production |
| LOG_LEVEL | debug | warn |
| APP_VERSION | Set by CI/CD | Set by CI/CD |

### Secrets — Complete Flow

Secrets are managed through a **6-layer pipeline** that gets them from a developer's hands into a running container, without ever committing them to Git:

```
Developer (terraform apply -var="db_password=...")
    │
    ▼
Layer 1: AWS Secrets Manager             ◄── secrets stored here, encrypted at rest
    │
    ▼
Layer 2: IAM Role (IRSA)                 ◄── only the ESO pod can read them
    │
    ▼
Layer 3: External Secrets Operator        ◄── runs in kube-system, syncs secrets
    │
    ▼
Layer 4: ExternalSecret CR               ◄── declares what to sync and how often
    │
    ▼
Layer 5: Kubernetes Secret                ◄── auto-created/updated by ESO
    │
    ▼
Layer 6: Pod env vars (DB_PASSWORD, API_KEY)  ◄── app reads process.env.*
```

#### Layer 1 — Secrets Created via Terraform (`terraform/secrets.tf`)

Two secrets are provisioned in AWS Secrets Manager:

| Secret Name | JSON Structure | Purpose |
|-------------|---------------|---------|
| `icounter/db-password` | `{"password": "..."}` | Database password |
| `icounter/api-key` | `{"key": "..."}` | API key |

The actual values come from Terraform variables (`var.db_password`, `var.api_key`) which are marked `sensitive = true` — they never appear in plan output, state logs, or Git. You pass them at apply time:

```bash
terraform apply -var="db_password=MyS3cretPass" -var="api_key=sk-abc123"
```

#### Layer 2 — IAM Controls Who Can Read Them (`terraform/iam.tf`)

A dedicated IAM role `icounter-external-secrets` is created using **IRSA** (IAM Roles for Service Accounts):

- **Trust policy** — only the Kubernetes ServiceAccount `external-secrets` in the `kube-system` namespace can assume this role (enforced via OIDC federation with EKS)
- **Permissions** — only `secretsmanager:GetSecretValue` and `secretsmanager:DescribeSecret`, scoped to the exact two secret ARNs (least privilege)

```
OIDC Trust Chain:
  EKS OIDC Provider
    └── Condition: sub = "system:serviceaccount:kube-system:external-secrets"
    └── Condition: aud = "sts.amazonaws.com"
        └── Grants: sts:AssumeRoleWithWebIdentity
            └── To: icounter-external-secrets IAM role
                └── Allows: GetSecretValue, DescribeSecret
                    └── Only on: icounter/db-password, icounter/api-key ARNs
```

Even if another pod or ServiceAccount is compromised, it **cannot** read these secrets — only the ESO pod can.

#### Layer 3 — External Secrets Operator Bridges AWS to Kubernetes

**ClusterSecretStore** (`helm/external-secrets/templates/clustersecretstore.yaml`) configures ESO to talk to AWS:

```yaml
spec:
  provider:
    aws:
      service: SecretsManager
      region: "ap-south-1"
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets      # the IRSA-annotated ServiceAccount
            namespace: kube-system
```

ESO uses the ServiceAccount's IRSA annotation to assume the IAM role and authenticate to AWS Secrets Manager — **no static AWS credentials needed inside the cluster**. The ESO pod runs on core infrastructure nodes (has `CriticalAddonsOnly` toleration + `core-infra` nodeSelector).

#### Layer 4 — ExternalSecret CR Pulls Secrets into Kubernetes

When `externalSecrets.enabled: true`, the Helm chart (`helm/icounter-api/templates/externalsecret.yaml`) creates an `ExternalSecret` custom resource:

```yaml
spec:
  refreshInterval: "1h"                # re-sync from AWS every hour
  secretStoreRef:
    name: aws-secrets-manager          # references the ClusterSecretStore
    kind: ClusterSecretStore
  target:
    name: icounter-api                 # name of the K8s Secret to create
    creationPolicy: Owner              # ESO owns and manages this Secret
  data:
    - secretKey: DB_PASSWORD           # key in the K8s Secret
      remoteRef:
        key: icounter/db-password      # AWS Secrets Manager secret name
        property: password             # JSON field to extract
    - secretKey: API_KEY
      remoteRef:
        key: icounter/api-key
        property: key
```

ESO watches this CR, reads the values from AWS Secrets Manager, and creates/updates a Kubernetes `Secret` named `icounter-api`.

#### Layer 5 — Dual-Mode Secret Creation (ExternalSecret vs Static)

The Helm chart supports two modes, controlled by `externalSecrets.enabled`:

| Mode | When | How It Works | Files |
|------|------|-------------|-------|
| **ExternalSecret** (`enabled: true`) | Production | ESO syncs AWS Secrets Manager → K8s Secret automatically | `externalsecret.yaml` is rendered, `secret.yaml` is **not** |
| **Static Secret** (`enabled: false`) | Staging / Dev | Plain K8s Secret with base64 values from Helm values | `secret.yaml` is rendered, `externalsecret.yaml` is **not** |

The static fallback (`helm/icounter-api/templates/secret.yaml`):
```yaml
{{- if not .Values.externalSecrets.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: icounter-api
type: Opaque
data:
  DB_PASSWORD: {{ .Values.secrets.dbPassword }}    # base64-encoded
  API_KEY: {{ .Values.secrets.apiKey }}             # base64-encoded
{{- end }}
```

Both modes produce the same Kubernetes Secret name (`icounter-api`), so the Deployment template doesn't need to change.

#### Layer 6 — Pod Consumes Secrets as Environment Variables

The Deployment (`helm/icounter-api/templates/deployment.yaml`) injects both config and secrets:

```yaml
envFrom:
  - configMapRef:
      name: icounter-api       # non-sensitive: NODE_ENV, LOG_LEVEL, APP_VERSION
  - secretRef:
      name: icounter-api       # secrets: DB_PASSWORD, API_KEY
```

All keys in the Secret become environment variables. The app reads them as `process.env.DB_PASSWORD` and `process.env.API_KEY`.

**Auto-restart on secret change:** The Deployment has checksum annotations:
```yaml
annotations:
  checksum/config: {{ include ... "/configmap.yaml" | sha256sum }}
  checksum/secret: {{ include ... "/secret.yaml" | sha256sum }}
```
When the secret content changes, the checksum changes, which triggers a rolling deployment — pods pick up new values automatically with zero downtime.

### CI/CD Secrets (Separate Path)

CI/CD pipelines use their own credential stores for **infrastructure access only** — these credentials never enter the container image or Kubernetes cluster:

| System | Credential | Purpose |
|--------|-----------|---------|
| **GitHub Actions** | `secrets.AWS_ACCESS_KEY_ID` | AWS IAM access key for ECR push, EKS deploy |
| **GitHub Actions** | `secrets.AWS_SECRET_ACCESS_KEY` | AWS IAM secret key |
| **Jenkins** | `aws-credentials` (Jenkins Credentials) | AWS access key + secret, wrapped in `withCredentials` blocks |
| **Jenkins** | `ecr-registry-url` (Secret Text) | ECR registry URL |

Jenkins credentials are automatically cleaned up after each build via `cleanWs()`.

### Security Guardrails Across the Pipeline

| Layer | Protection |
|-------|-----------|
| **Git** | No secrets in code — `sensitive = true` in Terraform, empty defaults in Helm values |
| **AWS** | Encrypted at rest in Secrets Manager, IAM scoped to exact secret ARNs |
| **Kubernetes** | IRSA — no static AWS credentials stored inside the cluster |
| **Pod** | Non-root user (UID 100), read-only filesystem, all Linux capabilities dropped |
| **Network** | NetworkPolicy restricts ingress to VPC CIDR only |
| **Image** | Multi-stage Docker build, no secrets baked into layers |
| **CI/CD** | Credentials scoped to CI runner only, never passed to application |

### How to Rotate a Secret

```bash
# 1. Update the value in AWS Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id icounter/db-password \
  --secret-string '{"password": "new-password"}' \
  --region ap-south-1

# 2. ESO automatically detects the change within 1 hour (refreshInterval)
#    and updates the Kubernetes Secret

# 3. The checksum annotation triggers a rolling restart
#    so pods pick up the new value with zero downtime

# To force an immediate sync instead of waiting:
kubectl annotate externalsecret icounter-api -n icounter \
  force-sync=$(date +%s) --overwrite

# To verify the secret was synced:
kubectl get externalsecret icounter-api -n icounter -o jsonpath='{.status.conditions}'
```

> **Note:** No automatic rotation is configured (e.g., AWS Secrets Manager rotation Lambda). Rotation is manual — you update the value in AWS, and ESO propagates it to the cluster.

---

## 9. Security Hardening

### Pod & Container Security Context

The Deployment template enforces strict security constraints at both pod and container level:

**Pod-level:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `runAsNonRoot` | `true` | Kubelet refuses to start the container if it resolves to UID 0 |
| `runAsUser` | `100` | Enforces UID 100 (matches Alpine's `appuser`) regardless of Dockerfile |
| `runAsGroup` | `101` | Enforces GID 101 (matches Alpine's `appgroup`) |
| `fsGroup` | `101` | Volumes are writable by the group |
| `seccompProfile` | `RuntimeDefault` | Blocks ~40 dangerous syscalls (mount, reboot, ptrace) |

**Container-level:**

| Setting | Value | Purpose |
|---------|-------|---------|
| `allowPrivilegeEscalation` | `false` | Blocks setuid binaries and privilege escalation |
| `readOnlyRootFilesystem` | `true` | Container filesystem is read-only (writable `/tmp` via emptyDir) |
| `capabilities.drop` | `[ALL]` | Removes all Linux capabilities — the Express app needs none |

### ServiceAccount

A dedicated ServiceAccount with `automountServiceAccountToken: false` — the Express app has no need for Kubernetes API access. Supports IRSA annotations for future AWS API access:

```yaml
serviceAccount:
  create: true
  automountServiceAccountToken: false
  annotations: {}
  # annotations:
  #   eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/my-role
```

### NetworkPolicy

Controls traffic in and out of application pods:

```
Ingress: VPC CIDR (10.0.0.0/16) ──> TCP 3000 ──> Pods
Egress:  Pods ──> UDP/TCP 53 (kube-system DNS)
         Pods ──> 0.0.0.0/0 (databases, external APIs)
```

- **Ingress** is restricted to the VPC CIDR on the container port. Since the ALB uses `target-type: ip`, traffic arrives from VPC ENIs, so a CIDR-based rule is used instead of a pod selector.
- **Egress DNS** is limited to the `kube-system` namespace where CoreDNS runs.
- **Egress outbound** allows all other traffic for database and external API connectivity.
- **Enforcement** requires the VPC CNI addon with `enableNetworkPolicy = true` (configured in Terraform).

### PodDisruptionBudget

```yaml
podDisruptionBudget:
  enabled: true
  minAvailable: 1
```

Ensures at least one pod survives voluntary disruptions — node drains, cluster upgrades, and Karpenter spot instance consolidation. Critical because the production NodePool uses spot instances with `WhenEmptyOrUnderutilized` consolidation, which actively rotates nodes.

### Image Scanning

ECR's `scan_on_push` (backed by AWS Inspector) scans every pushed image. The Jenkins pipeline waits for scan results and blocks deployment if CRITICAL vulnerabilities are found.

---

## API Endpoints

The application is exposed via AWS ALB at:

```
http://k8s-icounter-icounter-9befeeafff-1833990550.ap-south-1.elb.amazonaws.com
```

| Endpoint | URL | Description |
|----------|-----|-------------|
| **Health Check** | `/health` | Returns `{ status: "healthy" }` with timestamp and app version |
| **API Root** | `/api` | Returns welcome message and current environment |
| **API Info** | `/api/info` | Returns service name and server uptime |

**Test the endpoints:**

```bash
curl http://k8s-icounter-icounter-9befeeafff-1833990550.ap-south-1.elb.amazonaws.com/health
curl http://k8s-icounter-icounter-9befeeafff-1833990550.ap-south-1.elb.amazonaws.com/api
curl http://k8s-icounter-icounter-9befeeafff-1833990550.ap-south-1.elb.amazonaws.com/api/info
```

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
