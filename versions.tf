terraform {
  required_version = ">= 1.11"

  # Pre-existing bucket required. Bootstrap with:
  #   aws s3api create-bucket --bucket <name> --region eu-central-1 \
  #     --create-bucket-configuration LocationConstraint=eu-central-1
  #   aws s3api put-bucket-versioning --bucket <name> \
  #     --versioning-configuration Status=Enabled
  #
  # key is intentionally absent: it is supplied per environment via -backend-config.
  # See backends/dev.hcl and backends/prd.hcl.
  # Using the same key for two environments causes the second apply to overwrite
  # the first environment's state, silently destroying its resources on the next plan.
  #
  # No DynamoDB locking - safe for single operator.
  # Add: dynamodb_table = "terraform-locks" for team concurrent use.
  backend "s3" {
    bucket  = "my-terraform-state-bucket" # replace
    region  = "eu-central-1"
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
    # TLS provider: fetches EKS OIDC issuer certificate thumbprint for IRSA
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2"
    }
    # helm v3 migrated to Terraform Plugin Framework (Protocol v6).
    # Breaking changes from v2: kubernetes/exec/set/set_sensitive blocks are now
    # object attributes (= { }) and set is a list of objects (= [{ }]).
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
    }
  }
}

provider "aws" {
  region = var.region

  # All resources inherit these tags automatically
  default_tags {
    tags = local.tags
  }
}

# Token-based auth: aws_eks_cluster_auth fetches a short-lived STS token at apply
# time after the cluster exists. No aws CLI exec required, no kubeconfig dependency.
# helm v3 (Plugin Framework): kubernetes is now an object attribute, not a block.
provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.main.token
  }
}
