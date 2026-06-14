# main.tf — EKS template family
# Covers springboot-eks and nodejs-eks blueprints.
# providers.tf is NOT here — written at runtime by InfrastructureService.

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

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

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
# VPC FLOW LOGS (CKV_AWS_66)
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
# IAM — EKS Cluster Role
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
# EKS CLUSTER
# Secrets are encrypted with the project KMS key at the Kubernetes API level.
# Without envelope encryption, etcd data (including K8s Secrets) is stored in
# plaintext on the control plane's EBS volumes.
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
# RDS POSTGRESQL (springboot-eks blueprint)
# Same security posture as the ECS family: encrypted, private, not public.
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
# S3 + CLOUDFRONT (nodejs-eks blueprint)
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
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
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
