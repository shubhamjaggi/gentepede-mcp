# main.tf — EKS template family
# Covers springboot-eks and nodejs-eks blueprints.
# providers.tf is NOT here — written at runtime by InfrastructureService.

# ─────────────────────────────────────────────────────────────────────────────
# HOW RESOURCE GATING WORKS — Why this single file serves 2 blueprints
#
# Both EKS blueprints run containers on a shared Kubernetes cluster but need
# different data tiers. One boolean toggle controls the data layer:
#
#   count = var.enable_rds ? 1 : 0  →  RDS PostgreSQL (springboot-eks only)
#
# S3 + CloudFront (nodejs-eks) use a different pattern: gated by
# s3_bucket_name != "" rather than a boolean. When nodejs-eks is selected,
# Gentepede injects the s3_bucket_name variable; when springboot-eks is
# selected, it defaults to "" and no S3/CloudFront resources are created.
#
# The toggle derivation chain:
#
#   Step 1 — Blueprint JSON declares awsResources:
#               springboot-eks → includes "RDS_POSTGRES"
#               nodejs-eks     → does not include "RDS_POSTGRES"; includes "S3", "CLOUDFRONT"
#
#   Step 2 — InfrastructureService.injectDataTierToggles() for the eks family:
#               enable_rds = ("RDS_POSTGRES" in awsResources)
#
#   Step 3 — Written to terraform.tfvars:
#               springboot-eks: enable_rds = true,  s3_bucket_name = ""
#               nodejs-eks:     enable_rds = false, s3_bucket_name = "<user-supplied>"
#
#   Step 4 — Terraform evaluates count = var.enable_rds ? 1 : 0 for RDS resources,
#             and count = var.s3_bucket_name != "" ? 1 : 0 for S3/CloudFront resources.
#
# Per-blueprint resource summary:
#
#   Blueprint         VPC  EKS Cluster  Node Group  RDS  S3  CloudFront
#   ────────────────  ───  ───────────  ──────────  ───  ──  ──────────
#   springboot-eks    yes  yes          yes         yes  no  no
#   nodejs-eks        yes  yes          yes         no   yes yes
#
# Why Spring Boot on EKS uses RDS but not S3: the Spring Boot + JPA + Hibernate
# stack expects a relational database. S3 is object storage, not a database.
#
# Why Node.js on EKS uses S3 + CloudFront but not RDS: Node.js microservices
# commonly serve static assets and user uploads from S3 fronted by CloudFront
# for global CDN caching. A relational database would be a separate concern.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }

# ─────────────────────────────────────────────────────────────────────────────
# KMS — Dedicated project encryption key
# Used for EKS secrets encryption, RDS, S3, and CloudWatch Logs.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_kms_key" "main" {
  description             = "${var.project_name} - project encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project_name}-key"
  target_key_id = aws_kms_key.main.key_id
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC — Network isolation for EKS cluster
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  # enable_dns_hostnames + enable_dns_support: required for EKS cluster to resolve
  # service endpoints, RDS hostnames, and Kubernetes internal DNS (CoreDNS).
  # Also required for the ALB Ingress Controller to discover VPC resources by DNS.
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Environment                          = var.environment
    Project                              = var.project_name
    ManagedBy                            = "gentepede-mcp"
    # These tags are required by the AWS ALB Ingress Controller to discover subnets.
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# INTERNET GATEWAY — The VPC's Border Crossing
#
# An Internet Gateway (IGW) physically connects the VPC to the public internet.
# Without it, no traffic enters or leaves the VPC. Attaching it doesn't expose
# any resource — exposure requires a public IP, a route table entry pointing to
# the IGW, and a permissive security group. Only the ALB satisfies all three.
# EKS worker nodes and RDS live in private subnets with no IGW route.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# SUBNETS — Network Partitions with Different Exposure Levels
#
# Same public/private split as the ECS template. Public subnets route to the
# Internet Gateway (for the ALB Ingress Controller). Private subnets route to
# the NAT Gateway (for EKS worker nodes, RDS).
#
# EKS-SPECIFIC SUBNET TAGS:
# The kubernetes.io/* tags are NOT decorative — they are functional requirements
# for the AWS Load Balancer Controller (the Kubernetes controller that creates
# real AWS ALBs from Kubernetes Ingress resources).
#
#   "kubernetes.io/role/elb" = "1"
#     On PUBLIC subnets. Tells the ALB Controller: "create internet-facing ALBs
#     in these subnets." Without this tag, the controller cannot find public
#     subnets and fails to provision the ALB.
#
#   "kubernetes.io/role/internal-elb" = "1"
#     On PRIVATE subnets. For internal (cluster-internal) load balancers only.
#     Not used in this template but tagged for completeness.
#
#   "kubernetes.io/cluster/<cluster-name>" = "shared"
#     Required for the EKS cluster to discover which subnets belong to it.
#     "shared" means multiple clusters can use the same subnets (vs "owned"
#     which gives one cluster exclusive control).
#
# map_public_ip_on_launch = true (public subnets only):
#   ALB nodes (the actual ALB network interfaces) need public IPs to accept
#   traffic. In EKS, the ALB Controller provisions ALB nodes in public subnets.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  # ALB Ingress Controller requires map_public_ip_on_launch for ALB node discovery.
  map_public_ip_on_launch = true

  tags = {
    Environment                                     = var.environment
    Project                                         = var.project_name
    ManagedBy                                       = "gentepede-mcp"
    Tier                                            = "public"
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Environment                                     = var.environment
    Project                                         = var.project_name
    ManagedBy                                       = "gentepede-mcp"
    Tier                                            = "private"
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/${var.project_name}-eks" = "shared"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ELASTIC IP (EIP) + NAT GATEWAY — Controlled Outbound Internet Access
#
# EKS worker nodes in private subnets need outbound internet access to pull
# container images from ECR and call AWS APIs. The NAT Gateway (in the public
# subnet) translates their private IPs to the EIP for outbound requests, without
# giving nodes any public IP or allowing inbound internet connections to them.
# See the ECS template's NAT Gateway section for the full concept explanation.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ROUTE TABLES — How Traffic Knows Where to Go
#
# Route tables tell the VPC's router where to send traffic based on destination IP.
# Public subnets route 0.0.0.0/0 to the Internet Gateway (bidirectional internet).
# Private subnets route 0.0.0.0/0 to the NAT Gateway (outbound only, no inbound).
# aws_route_table_association binds a route table to a specific subnet.
# See the ECS template's Route Tables section for the full concept explanation.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC FLOW LOGS (CKV_AWS_66) — Network Traffic Audit Trail
#
# Flow logs capture metadata (src/dst IP, ports, protocol, ACCEPT/REJECT) for
# all traffic in the VPC. Essential for security incident investigation and
# compliance. Stored in S3 (cheaper than CloudWatch for high-volume data).
# See the ECS template's VPC Flow Logs section for the full concept explanation.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "flow_logs" {
  bucket        = "${var.project_name}-vpc-flow-logs"
  force_destroy = true

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket                  = aws_s3_bucket.flow_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_flow_log" "main" {
  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.flow_logs.arn
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.main.id
  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM — Roles for EKS Cluster and Worker Nodes
#
# IAM (Identity and Access Management) controls what AWS services a resource is
# permitted to call. EKS needs two separate IAM roles:
#
# 1. EKS CLUSTER ROLE (aws_iam_role.eks_cluster):
#    Assumed by the EKS CONTROL PLANE (AWS's managed Kubernetes API server,
#    scheduler, etc.). The control plane needs AWS permissions to:
#    - Create and manage Elastic Network Interfaces in your VPC (for pod networking)
#    - Create security group rules for pod-to-pod and pod-to-service communication
#    - Describe EC2 resources to find your subnets and instances
#    The AmazonEKSClusterPolicy managed policy grants exactly these permissions.
#    You cannot create an EKS cluster without this role.
#
# 2. EKS NODE ROLE (aws_iam_role.eks_node):
#    Assumed by the EC2 WORKER NODES (the EC2 instances where your pods run).
#    Worker nodes are EC2 instances, so their trust policy says "ec2.amazonaws.com".
#    Three managed policies are attached:
#
#    AmazonEKSWorkerNodePolicy:
#      Allows nodes to register themselves with the EKS cluster, describe their
#      own EC2 metadata, and participate in cluster autoscaling.
#
#    AmazonEKS_CNI_Policy (Container Network Interface policy):
#      The VPC CNI plugin (aws-node DaemonSet) runs on each node and manages
#      pod networking. It needs to:
#        - Assign secondary private IP addresses to EC2 network interfaces
#          (each pod gets its own VPC IP address — this is how EKS gives pods
#          routable VPC IPs without NAT between pods and other VPC resources)
#        - Create and attach ENIs to nodes as pod capacity grows
#      Without this policy, pods cannot get IP addresses and the cluster breaks.
#
#    AmazonEC2ContainerRegistryReadOnly:
#      Allows worker nodes to pull Docker images from ECR (Elastic Container
#      Registry). Without this, kubectl apply deployments fail with "image pull
#      failed" errors because nodes can't authenticate to ECR.
#
# TRUST POLICY — who can assume the role:
#   eks.amazonaws.com  → for the cluster role (the EKS service assumes it)
#   ec2.amazonaws.com  → for the node role (EC2 instances assume it)
#
# Why separate cluster and node roles?
#   The control plane doesn't need ECR access. The nodes don't need cluster-level
#   network configuration permissions. Keeping them separate limits blast radius.
# ─────────────────────────────────────────────────────────────────────────────
# The EKS service itself needs this role to manage AWS resources on your behalf.
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "eks_cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.project_name}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume.json
  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ─── EKS Node Group Role ──────────────────────────────────────────────────────

data "aws_iam_policy_document" "eks_node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.project_name}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume.json
  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_iam_role_policy_attachment" "eks_worker_node" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ─────────────────────────────────────────────────────────────────────────────
# AMAZON EKS — Managed Kubernetes Control Plane
#
# Amazon EKS (Elastic Kubernetes Service) runs the Kubernetes control plane for
# you. AWS manages the API server, etcd, scheduler, and controller manager.
# You provide worker nodes (EC2 instances via the node group below) where pods run.
#
# EKS vs ECS Fargate — when to choose which:
#   ECS Fargate: simpler, fully serverless, ideal for 1–3 services that don't
#                need the full Kubernetes API (no Helm, no operators, no CRDs)
#   EKS:         full Kubernetes API — use when you need multiple services sharing
#                a cluster, Helm chart deployments, NetworkPolicy, HPA/KEDA
#                autoscaling, or existing Kubernetes tooling/expertise
#
# Two resources form the cluster:
#   aws_eks_cluster    — the managed control plane. AWS guarantees multi-AZ HA.
#                        Billed at ~$0.10/hr regardless of workload.
#   aws_eks_node_group — managed pool of EC2 worker nodes where pods schedule.
#                        AWS handles node registration, upgrades, and replacement.
#
# Kubernetes Secrets are encrypted at the Kubernetes API level with the project
# KMS key via envelope encryption. Without this, etcd data (including K8s Secrets)
# is stored in plaintext on the control plane's EBS volumes.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    endpoint_private_access = true
    # endpoint_public_access allows kubectl from your workstation during development.
    # In production, set false and access the cluster from within the VPC only.
    endpoint_public_access = true
    security_group_ids     = []
  }

  # Encrypt Kubernetes Secrets at rest with the project KMS key.
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.main.arn
    }
  }

  # enabled_cluster_log_types: sends EKS control plane logs to CloudWatch Logs.
  # Each type is a different Kubernetes component's output:
  #   api           — Kubernetes API server request logs (who called what endpoint)
  #   audit         — Kubernetes audit logs (RBAC decisions, resource CRUD events)
  #   authenticator — IAM authentication logs (who authenticated to the cluster)
  #   controllerManager — garbage collection, node lifecycle, replica management
  #   scheduler     — pod scheduling decisions (which pod went to which node)
  # These are essential for security investigations ("who deleted that pod?") and
  # troubleshooting ("why won't this pod schedule?"). They go to a CloudWatch log
  # group that AWS manages; you pay per GB ingested.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# EKS NODE GROUP — Managed node group in private subnets
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# EKS NODE GROUP — The Worker Machines Where Your Pods Actually Run
#
# While aws_eks_cluster provisions the Kubernetes control plane (API server,
# scheduler, etcd — all managed by AWS), a Node Group provides the EC2 instances
# where your actual pods run. Without worker nodes, Kubernetes has nowhere to
# schedule pods.
#
# MANAGED NODE GROUP:
#   "Managed" means AWS handles node bootstrapping, AMI updates, and replacement.
#   When you update the node group's Kubernetes version or AMI, AWS automatically
#   cordons old nodes (stops scheduling new pods to them), drains them (moves
#   existing pods to healthy nodes), terminates the old node, and launches a new
#   one. You don't need to SSH in and manually upgrade nodes.
#
# instance_types = [var.node_instance_type]:
#   The EC2 instance type for worker nodes. t3.medium (2 vCPU, 4 GB) is the
#   minimum viable size for running Kubernetes system pods + your application.
#   Production workloads typically need m5.large or larger.
#
# scaling_config:
#   desired_size: the current number of nodes to maintain
#   min_size: the floor — Cluster Autoscaler won't scale below this
#   max_size: the ceiling — Cluster Autoscaler won't scale above this
#   (Cluster Autoscaler is NOT installed by this template — these bounds are
#   for manual or external autoscaler use. The HPA in the Helm chart scales
#   pods; if more pods need scheduling than nodes can fit, add a Cluster Autoscaler)
#
# update_config.max_unavailable = 1:
#   During a rolling node update, at most 1 node can be unavailable simultaneously.
#   This ensures the cluster maintains capacity throughout the upgrade. With 2 nodes
#   (the default desired_size), this means one node is updated at a time.
#
# subnet_ids = aws_subnet.private[*].id:
#   Worker nodes live in PRIVATE subnets. They have no public IPs. The cluster's
#   API server endpoint is accessed from the internet (endpoint_public_access = true)
#   but the nodes themselves are not publicly reachable.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_count
    min_size     = 1
    max_size     = var.node_count * 2
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node,
    aws_iam_role_policy_attachment.eks_cni,
    aws_iam_role_policy_attachment.ecr_read
  ]

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# RDS POSTGRESQL — Managed Relational Database (springboot-eks blueprint)
#
# Same managed PostgreSQL as the ECS family. Spring Boot + JPA connects to this
# endpoint. The database lives in private subnets; EKS worker nodes reach it
# via the RDS security group, which permits port 5432 from node subnet CIDRs.
#
# This block is only created when enable_rds = true (springboot-eks blueprint).
# For nodejs-eks, count = 0 and no RDS resources are created.
#
# Same security posture as the ECS family: encrypted at rest, private subnets,
# not publicly accessible (CKV_AWS_17, CKV_AWS_23).
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# SECURITY GROUPS — Stateful, Resource-Level Firewalls
#
# Security Groups control inbound and outbound traffic for individual resources.
# They are stateful: if an inbound connection is allowed, the return traffic is
# automatically permitted without an explicit egress rule.
#
# In the EKS template, the networking design is different from ECS because
# Kubernetes manages pod networking (via the VPC CNI plugin). Worker nodes get
# EC2 security groups, and pod-to-pod traffic within the cluster is handled by
# the CNI and NetworkPolicy (see helm-chart/templates/network-policy.yaml).
#
# This template only creates a security group for RDS (when enable_rds = true),
# restricting PostgreSQL access to the EKS worker node private subnet CIDRs.
# ─────────────────────────────────────────────────────────────────────────────
resource "aws_security_group" "rds" {
  count       = var.enable_rds ? 1 : 0
  name        = "${var.project_name}-rds-sg"
  description = "RDS: inbound from EKS worker nodes only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "PostgreSQL from EKS node group CIDR"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.10.0/24", "10.0.11.0/24"]
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# A DB Subnet Group tells RDS which subnets it can place the instance in.
# Must span at least two AZs (even without Multi-AZ) for future failover readiness.
# Private subnets only — the database has no public IP and is unreachable from
# the internet even if the security group were misconfigured.
resource "aws_db_subnet_group" "main" {
  count       = var.enable_rds ? 1 : 0
  name        = "${var.project_name}-db-subnet-group"
  subnet_ids  = aws_subnet.private[*].id
  description = "Private subnets for RDS"

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_db_instance" "postgres" {
  count                   = var.enable_rds ? 1 : 0
  identifier              = "${var.project_name}-postgres"
  engine                  = "postgres"
  engine_version          = "16.3"
  instance_class          = var.db_instance_class
  allocated_storage       = var.db_allocated_storage
  max_allocated_storage   = var.db_allocated_storage * 5

  db_name  = var.db_name
  username = var.db_username
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  # CKV_AWS_17 — database not reachable from the internet
  publicly_accessible = false
  # CKV_AWS_23 — encrypted at rest with project KMS key
  storage_encrypted   = true
  kms_key_id          = aws_kms_key.main.arn

  skip_final_snapshot     = true
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:05:00-sun:06:00"

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 + CLOUDFRONT — Object Storage + CDN (nodejs-eks blueprint)
#
# Amazon S3 (Simple Storage Service) stores objects (files, uploads, static assets)
# with eleven 9s of durability. It is not a file system or database — it is
# key-value object storage accessed via HTTP API or AWS SDK.
#
# Amazon CloudFront is a CDN (Content Delivery Network) with 400+ edge locations
# worldwide. It caches S3 content close to users, reducing latency and S3 costs.
#
# Why S3 + CloudFront instead of serving from the Node.js pod?
#   Serving large files from the Node.js container wastes container CPU/memory
#   and doesn't scale. S3 + CloudFront offloads static content delivery entirely,
#   letting the Node.js pod focus on API logic.
#
# Security model (Origin Access Control):
#   The S3 bucket has ALL public access blocked. CloudFront reaches S3 through
#   an OAC (Origin Access Control) — a service principal that signs requests with
#   SigV4. The bucket policy allows s3:GetObject only to this CloudFront distribution
#   via a SourceArn condition. Users cannot access S3 directly — only through the CDN.
#
# These blocks are only created when s3_bucket_name != "" (nodejs-eks blueprint).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "app" {
  count  = var.s3_bucket_name != "" ? 1 : 0
  bucket = var.s3_bucket_name

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_s3_bucket_versioning" "app" {
  count  = var.s3_bucket_name != "" ? 1 : 0
  bucket = aws_s3_bucket.app[0].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  count  = var.s3_bucket_name != "" ? 1 : 0
  bucket = aws_s3_bucket.app[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    # bucket_key_enabled reduces KMS API call volume and cost. Without it, every
    # S3 PUT/GET generates a KMS API call to encrypt/decrypt using the CMK.
    # With it, S3 generates a per-bucket data key from the CMK and caches it —
    # dramatically reducing KMS API calls for high-throughput buckets.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "app" {
  count                   = var.s3_bucket_name != "" ? 1 : 0
  bucket                  = aws_s3_bucket.app[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─────────────────────────────────────────────────────────────────────────────
# CLOUDFRONT — CDN in front of the S3 content bucket (nodejs-eks blueprint)
# The bucket stays fully private (public access blocked above); CloudFront reaches
# it through an Origin Access Control, and the bucket policy trusts only this one
# distribution. CKV_AWS_2: viewers are forced onto HTTPS.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudfront_origin_access_control" "app" {
  count                             = var.s3_bucket_name != "" ? 1 : 0
  name                              = "${var.project_name}-oac"
  description                       = "OAC for ${var.project_name} S3 origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "app" {
  count           = var.s3_bucket_name != "" ? 1 : 0
  enabled         = true
  is_ipv6_enabled = true
  price_class     = var.cloudfront_price_class
  comment         = "${var.project_name} S3 content CDN"

  origin {
    domain_name              = aws_s3_bucket.app[0].bucket_regional_domain_name
    origin_id                = "s3-${var.project_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.app[0].id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-${var.project_name}"
    viewer_protocol_policy = "redirect-to-https" # force HTTPS for all viewers

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    # geo_restriction: block or allow access from specific countries.
    # "none" = no geographic restrictions (all countries can access the CDN).
    # Use "blacklist" or "whitelist" with a `locations` list if needed.
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # cloudfront_default_certificate = true uses the *.cloudfront.net domain.
    # This gives you HTTPS for free but with a CloudFront-owned domain (e.g.,
    # d1abc.cloudfront.net). To use a custom domain (cdn.myapp.com):
    #   1. Replace this with: acm_certificate_arn = "arn:aws:acm:us-east-1:..."
    #   2. Add: ssl_support_method = "sni-only"
    #   3. Create a CNAME dns record pointing cdn.myapp.com → the cloudfront domain
    # Note: ACM certificates for CloudFront MUST be in us-east-1 regardless of
    # where your other resources are — CloudFront is a global service that only
    # reads certificates from us-east-1.
    cloudfront_default_certificate = true
    # minimum_protocol_version: reject connections using TLS 1.0 or 1.1.
    # "TLSv1.2_2021" requires TLS 1.2+ and uses a modern cipher suite list.
    # TLS 1.0/1.1 have known vulnerabilities and are deprecated by all major browsers.
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# Bucket policy: allow s3:GetObject only to the CloudFront service principal, and
# only when the request originates from this distribution (SourceArn condition).
# This is not a public grant, so it coexists with block_public_policy = true.
data "aws_iam_policy_document" "s3_cloudfront" {
  count = var.s3_bucket_name != "" ? 1 : 0

  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.app[0].arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.app[0].arn]
    }
  }
}

resource "aws_s3_bucket_policy" "app" {
  count  = var.s3_bucket_name != "" ? 1 : 0
  bucket = aws_s3_bucket.app[0].id
  policy = data.aws_iam_policy_document.s3_cloudfront[0].json
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────

output "eks_cluster_name" {
  description = "EKS cluster name. Use with: aws eks update-kubeconfig --name <value>"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint (springboot-eks blueprint)."
  value       = try(aws_db_instance.postgres[0].endpoint, "N/A — RDS not provisioned for this blueprint")
  sensitive   = true
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain for the S3 content CDN (nodejs-eks blueprint)."
  value       = try(aws_cloudfront_distribution.app[0].domain_name, "N/A — CloudFront not provisioned for this blueprint")
}

output "vpc_id" {
  description = "VPC ID for the EKS cluster."
  value       = aws_vpc.main.id
}
