# Terraform - AWS Web Application Infrastructure

Provisions a production-grade AWS environment for a containerised Spring Boot API.
One apply = one cluster. Run twice with different state keys for `dev` and `prd`.

---

## Architecture

```
                          Internet
                             |
                      [Internet Gateway]
                        /           \
              [Public Subnet AZ-a]  [Public Subnet AZ-b]
              [NAT Gateway]         (no NAT - cost tradeoff)
              [Nginx Ingress LB] <-- routes inbound HTTPS
                        \           /
              [Private Subnet AZ-a] [Private Subnet AZ-b]
              [EKS Nodes]           [EKS Nodes]
              [RDS Primary]         [RDS Standby]  <- Multi-AZ automatic failover
```

Traffic flows:
- **Inbound**: Internet -> IGW -> Nginx LB (public subnet) -> EKS pods (private subnet)
- **Egress**: EKS pods -> NAT GW (AZ-a only) -> IGW -> Internet
- **DB**: EKS pods -> RDS (same VPC, private subnet, port 5432 only)

| Layer    | Service                  | Notes                              |
|----------|--------------------------|------------------------------------|
| Compute  | EKS 1.35 managed nodes   | AL2023, t3.medium, 2-10 nodes      |
| Database | RDS PostgreSQL 17        | db.t4g.micro, Multi-AZ, gp3        |
| Storage  | S3                       | Versioned, private                 |
| Network  | VPC 10.0.0.0/16          | 2 public + 2 private subnets, 2 AZ |

---

## Files

| File                       | What it does                                                                  |
|----------------------------|-------------------------------------------------------------------------------|
| `versions.tf`              | Terraform version constraint, S3 backend, provider pins and provider blocks   |
| `variables.tf`             | All inputs with types, defaults, and descriptions                             |
| `locals.tf`                | AZ list, shared resource tags, OIDC provider URL, chart revision              |
| `data.tf`                  | Reads available AZs and current AWS account ID from AWS                       |
| `network.tf`               | VPC, subnets, IGW, NAT GW, route tables, RDS security group                  |
| `compute.tf`               | EKS cluster, node group, OIDC provider, addons, CloudWatch log group          |
| `database.tf`              | RDS instance, subnet group, write-only password                               |
| `storage.tf`               | S3 bucket (versioned, private)                                                |
| `addons.tf`                | Helm releases: nginx ingress, cert-manager, ArgoCD                            |
| `outputs.tf`               | kubectl config command, ArgoCD admin password, DB endpoint, S3 bucket name    |
| `terraform.tfvars.example` | Copy to `terraform.tfvars` and fill in before running                         |

---

## Prerequisites

- Terraform >= 1.11
- AWS CLI configured - `aws sts get-caller-identity` should succeed
- AWS identity with permissions: `eks:*`, `ec2:*`, `rds:*`, `s3:*`, `iam:*`,
  `logs:*`, `elasticloadbalancing:*`
- `aws` CLI available in `PATH` - used by the Helm provider for EKS auth

### Bootstrap the state bucket (once, before first init)

Terraform's S3 backend requires the bucket to exist before `terraform init` can run.
Create it manually once and reuse across all environments:

```bash
aws s3api create-bucket \
  --bucket my-terraform-state-bucket \
  --region eu-central-1 \
  --create-bucket-configuration LocationConstraint=eu-central-1

aws s3api put-bucket-versioning \
  --bucket my-terraform-state-bucket \
  --versioning-configuration Status=Enabled
```

Then update `bucket = "my-terraform-state-bucket"` in `versions.tf`.

---

## Deploy

### 1. Configure variables

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set cluster_name to match ArgoCD (e.g. dev-global-cluster-0)
```

### 2. Init with a per-environment state key

Each environment has its own backend config file under `backends/`. Pass it at init time:

```bash
# dev
terraform init -backend-config=backends/dev.hcl

# prd (switching in the same directory - -reconfigure replaces the active backend)
terraform init -reconfigure -backend-config=backends/prd.hcl
```

Both environments share one S3 bucket but isolate state in separate keys. Using the same
key would cause the second apply to overwrite the first environment's state.

### 3. Plan and apply

```bash
terraform plan
terraform apply
```

---

## Post-deploy wiring

`terraform apply` provisions the infrastructure: EKS cluster, RDS, S3, nginx,
cert-manager, and ArgoCD. ArgoCD config (ClusterIssuers, AppProject, ApplicationSet)
is managed separately in the spring-boot-api repo.

Configure kubectl after apply:

```bash
terraform output -raw kubeconfig_command | bash
```

### Access ArgoCD

```bash
# Get the initial admin password
terraform output -raw argocd_admin_password | bash

# Find the ArgoCD server URL
kubectl get svc argocd-server -n argocd
```

Bootstrap ArgoCD config from the spring-boot-api repo:

```bash
kubectl apply -f ../spring-boot-api/argocd/argocd-project.yaml
kubectl apply -f ../spring-boot-api/argocd/cluster-issuers.yaml
kubectl apply -f ../spring-boot-api/argocd/applicationset.yaml
```

Watch the spring-boot-api sync:

```bash
argocd login <argocd-server-ip>
argocd app list
```

### Destroying the environment

RDS has `deletion_protection = true`. Disable it before `terraform destroy`:

```bash
aws rds modify-db-instance \
  --db-instance-identifier webapp-<env> \
  --no-deletion-protection \
  --apply-immediately
# Wait ~1 minute for the change to apply, then:
terraform destroy
```

---

## Design decisions

**Flat file structure, no modules** - one directory, no module indirection. Each file
groups resources by concern (network, compute, database, storage). Easy to read top-to-bottom
and explain without jumping between directories.

**Write-only DB password** - `password_wo` (Terraform >= 1.11 + random >= 3.7 +
AWS provider >= 5.80) applies the generated password to RDS but never writes its value to
`.tfstate`. The state file is the most common source of leaked secrets. The trade-off:
you cannot retrieve the password after apply - see "Getting the DB password" above.

**RDS Multi-AZ** - the standby replica in a second AZ provides automatic failover in
~60 seconds if the primary fails. Without Multi-AZ, a single AZ outage takes the database
down until manual recovery. On `db.t4g.micro` this roughly doubles the DB cost (~$30/month
to ~$60/month) - an explicit HA trade-off, not an oversight.

**Graviton3 RDS instance (db.t4g.micro)** - ~20% cheaper and faster than the equivalent
Intel `db.t3.micro`. Graviton is ARM-based; PostgreSQL is fully compatible.

**Single NAT Gateway** - one NAT GW in AZ-a keeps egress costs low (~$32/month vs ~$64
for two). Trade-off: if AZ-a goes down, private subnets in AZ-b lose internet egress.
The code comment in `network.tf` shows how to extend to one NAT GW per AZ.

**EKS managed nodes over Fargate** - the spring-boot-api chart uses DaemonSets (vpc-cni,
kube-proxy) and `topologySpreadConstraints` with `kubernetes.io/hostname`. Fargate does not
support DaemonSets, so EC2-backed managed node groups are required.

**Kubernetes subnet tags** - the AWS Load Balancer Controller discovers subnets by tag.
Public subnets need `kubernetes.io/role/elb = 1` for internet-facing LoadBalancers (nginx
ingress). Private subnets need `kubernetes.io/role/internal-elb = 1` for internal ones.
Without these tags, `kubectl apply` succeeds but the LoadBalancer never gets an IP.

**Per-environment resource naming** - every resource name includes `${var.environment}`.
Both dev and prd can be applied in the same AWS account without naming conflicts on IAM
roles, RDS identifiers, or S3 buckets.

**Helm add-ons in Terraform** - nginx, cert-manager, and ArgoCD are installed via
`helm_release` resources rather than post-apply shell commands. This keeps infrastructure
in a single declarative apply. ArgoCD config (ClusterIssuers, AppProject, ApplicationSet)
lives in the spring-boot-api repo: clear separation between infra and application setup.
Trade-off: `terraform destroy` may fail if Helm releases have finalizers on custom
resources - delete ArgoCD Applications before destroying.

**In-cluster ArgoCD destination** - the ArgoCD Application uses
`destination.server: https://kubernetes.default.svc` (the cluster ArgoCD runs on)
instead of a registered external cluster URL. This avoids the `argocd cluster add`
step and works with no external DNS. The ApplicationSet in `spring-boot-api/argocd/`
covers the alternative multi-cluster pattern where one central ArgoCD manages both
dev and prd.

**No DynamoDB state locking** - safe for a single operator. For teams, add
`dynamodb_table = "terraform-locks"` to the backend block and create the table first.

**SSE-S3 omitted** - AWS encrypts all S3 objects by default since April 2023. Explicitly
configuring SSE-S3 is redundant. Upgrade to SSE-KMS only if you need customer-managed keys
for compliance.
