resource "aws_vpc" "main" {
  # 10.0.0.0/16 = 65,536 addresses. Subnets carved via cidrsubnet:
  #   public:  10.0.0.0/24, 10.0.1.0/24   (count.index 0, 1)
  #   private: 10.0.10.0/24, 10.0.11.0/24 (count.index + 10)
  # Gap between 1 and 10 leaves room for extra public subnets (e.g. 3rd AZ)
  # without renumbering private ones.
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "public" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project}-public-${count.index}"

    # Required by the AWS cloud controller / Load Balancer Controller to discover
    # which subnets are eligible for internet-facing LoadBalancer Services (nginx ingress).
    # Without this tag, the controller cannot find subnets and LB creation fails.
    "kubernetes.io/role/elb" = "1"

    # "owned" means this cluster is the sole owner of the subnet.
    # Use "shared" if multiple clusters share the same subnet.
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project}-private-${count.index}"

    # Marks subnets eligible for internal-only LoadBalancer Services.
    # EKS nodes run here - without this tag an internal LB (e.g. RDS proxy, internal ALB)
    # can't be placed in the correct subnets.
    "kubernetes.io/role/internal-elb" = "1"

    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

# Single NAT Gateway in AZ-0 for cost efficiency.
# Trade-off: if AZ-0 fails, private subnets in other AZs lose egress.
# For full AZ-level HA, deploy one per AZ:
#   count         = length(local.azs)
#   allocation_id = aws_eip.nat[count.index].id
#   subnet_id     = aws_subnet.public[count.index].id
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Security Groups ---

# EKS auto-creates and manages a cluster security group for control plane <-> node
# communication. We reference it for RDS access below.
# No manual SG needed for nodes - EKS assigns the cluster SG automatically.

resource "aws_security_group" "rds" {
  name   = "${var.project}-${var.environment}-rds"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }
}
