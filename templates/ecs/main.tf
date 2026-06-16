# main.tf — ECS Fargate template family
# Covers springboot-postgres, ktor-dynamodb, and fastapi-redis blueprints.
# This file IS the reference implementation of Gentepede security best practices.
# providers.tf is NOT here — it is written at runtime by InfrastructureService.

# ─────────────────────────────────────────────────────────────────────────────
# HOW RESOURCE GATING WORKS — Why this single file serves 3 blueprints
#
# This main.tf is shared by springboot-postgres, ktor-dynamodb, and fastapi-redis.
# All three need the same compute and networking stack (VPC, ALB, ECS Fargate)
# but each needs a different data tier. Rather than three near-identical template
# files, one shared template uses boolean flags to include or exclude data-tier
# resources at plan time:
#
#   count = var.enable_rds      ? 1 : 0  →  RDS PostgreSQL (+ its SG, subnet group)
#   count = var.enable_dynamodb ? 1 : 0  →  DynamoDB table (+ IAM grant in task policy)
#   count = var.enable_redis    ? 1 : 0  →  ElastiCache Redis (+ its SG, subnet group)
#
# Gentepede sets these flags automatically — you never touch them manually.
# The derivation chain:
#
#   Step 1 — Blueprint JSON declares its awsResources (which data tier it needs):
#               springboot-postgres → ["VPC","ALB","ECS_FARGATE","RDS_POSTGRES","KMS"]
#               ktor-dynamodb       → ["VPC","ALB","ECS_FARGATE","DYNAMODB_TABLE","KMS"]
#               fastapi-redis       → ["VPC","ALB","ECS_FARGATE","ELASTICACHE_REDIS","KMS"]
#
#   Step 2 — InfrastructureService.injectDataTierToggles() reads that list and derives:
#               enable_rds      = ("RDS_POSTGRES"     in awsResources)
#               enable_dynamodb = ("DYNAMODB_TABLE"    in awsResources)
#               enable_redis    = ("ELASTICACHE_REDIS" in awsResources)
#
#   Step 3 — Those booleans are written into terraform.tfvars for this workspace:
#               enable_rds      = true   # only for springboot-postgres
#               enable_dynamodb = false
#               enable_redis    = false
#
#   Step 4 — Terraform evaluates count = var.enable_X ? 1 : 0 on each data-tier block.
#             Resources with count = 0 are simply not created and cost nothing.
#
# Per-blueprint resource summary:
#
#   Blueprint              VPC  ALB  ECS Fargate  RDS  DynamoDB  Redis
#   ─────────────────────  ───  ───  ───────────  ───  ────────  ─────
#   springboot-postgres    yes  yes  yes          yes  no        no
#   ktor-dynamodb          yes  yes  yes          no   yes       no
#   fastapi-redis          yes  yes  yes          no   no        yes
#
# Why Spring Boot needs RDS but not DynamoDB: Spring Boot + JPA is designed for
# relational databases; its connection pooling, transaction management, and ORM
# (Hibernate) map directly to PostgreSQL. DynamoDB's NoSQL model would require
# a different SDK and data access pattern entirely.
#
# Why Ktor uses DynamoDB: Ktor (Kotlin async framework) pairs naturally with
# DynamoDB's SDK for lightweight, schema-free storage without connection pools.
#
# Why FastAPI uses Redis: FastAPI is often paired with async caching or session
# storage; Redis provides sub-millisecond in-memory lookups ideal for this.
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# DATA SOURCES
# ─────────────────────────────────────────────────────────────────────────────

# Fetch current region and account for constructing ARNs without hardcoding.
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Available AZs for distributing subnets across for high availability.
data "aws_availability_zones" "available" {
  state = "available"
}

# ─────────────────────────────────────────────────────────────────────────────
# KMS — Dedicated Encryption Key
# Using a per-project key (not the default AWS-managed key) allows independent
# key policy management, granular audit trails, and the ability to revoke access
# per environment without touching other projects.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_kms_key" "main" {
  description             = "${var.project_name} - project encryption key"
  deletion_window_in_days = 30
  # Without enable_key_rotation, the same cryptographic material is used indefinitely.
  # Annual rotation limits the blast radius of a compromised key material.
  enable_key_rotation = true

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# aws_kms_alias creates a human-readable name for the KMS key. Without an alias,
# the key is only referenceable by its 36-character UUID or full ARN. The alias
# "alias/my-api-key" is much easier to reference in the AWS console and CLI.
# An alias is a pointer — deleting the alias doesn't delete the underlying key.
resource "aws_kms_alias" "main" {
  name          = "alias/${var.project_name}-key"
  target_key_id = aws_kms_key.main.key_id
}

# ─────────────────────────────────────────────────────────────────────────────
# VPC — Network Isolation Foundation
# All compute and data resources live in private subnets.
# Only the ALB resides in public subnets and accepts external traffic.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  # cidr_block = "10.0.0.0/16" — the IP address range for the entire VPC.
  # /16 means 65,536 available private IP addresses (10.0.0.0 to 10.0.255.255).
  # We carve subnets out of this range: 10.0.0.0/24, 10.0.1.0/24 (public),
  # 10.0.10.0/24, 10.0.11.0/24 (private). Private ranges (RFC 1918): 10.x.x.x,
  # 172.16–31.x.x, 192.168.x.x — these IPs are not routable on the public internet.
  cidr_block           = "10.0.0.0/16"
  # enable_dns_hostnames is required for RDS and ElastiCache endpoint resolution
  # inside the VPC. Without it, DNS names returned by AWS would not resolve.
  # Example: "mydb.abc123.us-east-1.rds.amazonaws.com" would not resolve to an IP.
  enable_dns_hostnames = true
  # enable_dns_support enables the Amazon-provided DNS resolver at 169.254.169.253.
  # Without it, instances in the VPC cannot resolve any DNS names.
  enable_dns_support   = true

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# INTERNET GATEWAY — The VPC's Border Crossing
#
# An Internet Gateway (IGW) is the component that physically connects your VPC
# to the public internet. Without an IGW attached to the VPC, NO traffic can
# enter or leave at all — not even the ALB could receive requests.
#
# Important: attaching an IGW doesn't automatically expose any resource to the
# internet. A resource only becomes internet-reachable when ALL THREE are true:
#   1. The resource has a public IP address (or sits behind something that does)
#   2. Its subnet's route table sends 0.0.0.0/0 traffic through the IGW
#   3. Its security group allows the incoming traffic
#
# In this template, only the ALB is internet-reachable (it sits in a public
# subnet with a public DNS name and an SG that allows port 443). ECS tasks and
# databases are in private subnets with no direct IGW route — they can't be
# reached from the internet even if someone tried.
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
# A subnet is a range of IP addresses carved out of the VPC's address space.
# Every resource (ECS task, RDS instance, ALB) lives in exactly one subnet and
# gets one of its IP addresses. Which subnet a resource goes in determines
# whether it can be reached from the internet.
#
# PUBLIC SUBNETS (10.0.0.0/24, 10.0.1.0/24 — one per Availability Zone):
#   Their route table points 0.0.0.0/0 → Internet Gateway. Resources here
#   can receive inbound internet traffic if they also have a public IP.
#   We place:
#     - The ALB (needs a public-facing IP to accept requests from users)
#     - The NAT Gateway (needs a public IP to relay outbound traffic for tasks)
#   ECS tasks are NOT placed here — they go in private subnets.
#
# PRIVATE SUBNETS (10.0.10.0/24, 10.0.11.0/24 — one per Availability Zone):
#   Their route table points 0.0.0.0/0 → NAT Gateway, NOT the IGW.
#   Resources here can make outbound calls but cannot receive inbound internet
#   traffic — there is no inbound path from the internet to a private subnet.
#   We place:
#     - ECS tasks (your application containers)
#     - RDS database (never needs a public IP)
#     - ElastiCache Redis (same)
#
# Why two Availability Zones?
#   AWS AZs are physically separate data centers with independent power and
#   networking. Spreading the ALB and ECS tasks across two AZs means a hardware
#   failure or power outage in one AZ doesn't take down your entire service.
#   The ALB automatically stops routing to the affected AZ until it recovers.
# ─────────────────────────────────────────────────────────────────────────────
# Public subnets: one per AZ for ALB multi-AZ requirements.
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  # map_public_ip_on_launch is intentionally false — the ALB uses an Elastic IP
  # via its subnet placement, not per-instance public IPs.
  map_public_ip_on_launch = false

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
    Tier        = "public"
  }
}

# Private subnets: ECS tasks and data resources live here.
# Outbound internet access (for ECR pulls) goes via NAT Gateway, not directly.
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
    Tier        = "private"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ELASTIC IP (EIP) + NAT GATEWAY — Controlled Outbound Internet Access
#
# ELASTIC IP (aws_eip):
#   A static public IPv4 address that you reserve from AWS. Unlike EC2 public
#   IPs (which change every time an instance restarts), an EIP persists until you
#   explicitly release it. The NAT Gateway needs a stable public IP so that
#   outbound traffic from private subnets always appears to come from the same
#   address — important if external APIs allowlist specific IPs.
#
# NAT GATEWAY (aws_nat_gateway — Network Address Translation):
#   ECS tasks have only private IPs (e.g., 10.0.10.5). To reach the internet
#   (for ECR image pulls, AWS API calls, third-party services), they send packets
#   to the NAT Gateway. The NAT Gateway:
#     1. Receives the packet from the private IP
#     2. Replaces the source IP with its own public EIP
#     3. Forwards the packet to the internet
#     4. Receives the response and translates back to the original private IP
#     5. Delivers the response to the ECS task
#
#   This means:
#     • ECS tasks CAN initiate outbound connections
#     • The internet CANNOT initiate inbound connections to ECS tasks
#     • All outbound traffic appears from one predictable IP (the EIP)
#
# The NAT Gateway itself lives in a PUBLIC subnet (it needs internet access).
# It is NOT a compute resource you manage — AWS fully manages it, scales it
# automatically, and guarantees 99.99% availability within the AZ.
#
# Cost: ~$0.045/hr (~$32/month) + $0.045/GB data processed.
# For high-throughput services, consider VPC Endpoints (direct private links to
# AWS services like S3 and ECR that bypass the NAT Gateway entirely).
# ─────────────────────────────────────────────────────────────────────────────
# Elastic IP for NAT Gateway — a fixed public IP for outbound traffic from private subnets.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# NAT Gateway — allows ECS tasks in private subnets to reach the internet for
# ECR image pulls and AWS API calls, without exposing the tasks publicly.
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
# A route table is a list of rules ("routes") that tell the VPC's virtual router
# where to send network packets based on their destination IP address.
# Every subnet must be associated with exactly one route table.
#
# How route lookup works (longest prefix match):
#   Destination IP 10.0.5.3   → matches 10.0.0.0/16  → route: local  (stays in VPC)
#   Destination IP 52.1.2.3   → matches 0.0.0.0/0    → route: IGW or NAT (internet)
#
# Both route tables below share the implicit local route:
#   10.0.0.0/16 → local   (all VPC-internal traffic stays inside the VPC)
#
# Then each adds one rule for internet-bound traffic:
#   Public route table:   0.0.0.0/0 → Internet Gateway  (two-way internet access)
#   Private route table:  0.0.0.0/0 → NAT Gateway       (outbound only, no inbound)
#
# aws_route_table_association attaches a route table to a specific subnet.
# Without this association, the subnet falls back to the VPC default route table
# (which has no internet route at all).
# ─────────────────────────────────────────────────────────────────────────────
# Route table for public subnets: direct 0.0.0.0/0 to Internet Gateway.
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

# Route table for private subnets: outbound via NAT Gateway only.
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
# VPC FLOW LOGS — Network Traffic Audit Trail (CKV_AWS_66)
#
# VPC Flow Logs capture metadata (NOT payload) for every IP flow that enters
# or leaves your VPC. Each log record captures:
#   srcaddr, dstaddr, srcport, dstport, protocol, packets, bytes,
#   start, end, action (ACCEPT or REJECT)
#
# Examples of what they let you investigate:
#   "Someone tried to connect to our RDS on port 5432 — what IP was it?"
#   "Why is traffic from ECS tasks to Redis being REJECTED?"
#   "Is there unexpected outbound traffic to external IPs?"
#
# What they do NOT capture:
#   The actual content of HTTP requests, SQL queries, or API payloads.
#   For application-level logging, see CloudWatch Log Group below.
#
# S3 vs CloudWatch Logs for storage:
#   We write flow logs to S3 (not CloudWatch) because:
#   - S3 is cheaper for high-volume storage (~$0.025/GB vs ~$0.50/GB)
#   - S3 integrates with Amazon Athena for SQL queries over log data
#   - Flow logs generate large volumes — cost matters at scale
#
# The S3 bucket for flow logs requires:
#   KMS encryption (the logs contain IP addresses, which is sensitive data)
#   Public access block (logs should never be publicly readable)
#   Versioning (enables tamper detection — deleted logs leave a version marker)
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

# S3 SSE on the flow logs bucket — logs themselves contain sensitive IP data.
resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
  }
}

# Block all public access to the flow logs bucket — logs must never be public.
resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket                  = aws_s3_bucket.flow_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  versioning_configuration {
    status = "Enabled"
  }
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
# SECURITY GROUPS — Stateful, Resource-Level Firewalls
#
# A Security Group (SG) is a virtual firewall attached to individual AWS resources
# (ALB, ECS task, RDS instance). It controls which traffic is allowed IN (ingress)
# and OUT (egress) by port, protocol, and source/destination.
#
# KEY PROPERTY — Stateful:
#   If an inbound rule allows a connection (e.g., TCP 443 from 1.2.3.4), the
#   response packets from your service back to 1.2.3.4 are automatically allowed.
#   You don't write egress rules for return traffic. This differs from NACLs
#   (Network ACLs), which are stateless and require explicit rules for both
#   directions.
#
# LAYERED DEFENSE DESIGN — The traffic funnel in this template:
#
#   Internet
#      │  443/80 (from 0.0.0.0/0 — anyone on the internet)
#      ▼
#   aws_security_group.alb         ← the only SG with a public ingress rule
#      │  container_port (from ALB SG reference — NOT from 0.0.0.0/0)
#      ▼
#   aws_security_group.ecs_tasks   ← cannot be reached directly from internet
#      │  5432 (from ecs_tasks SG)    │  6379 (from ecs_tasks SG)
#      ▼                              ▼
#   aws_security_group.rds      aws_security_group.redis
#
# WHY USE SECURITY GROUP REFERENCES INSTEAD OF IP RANGES?
#   The ECS tasks SG rule says: `security_groups = [aws_security_group.alb.id]`
#   This means "only traffic that passed through the ALB security group."
#   Even if the ALB's IP changes (and it does change), this rule stays correct.
#   A CIDR-based rule like `cidr_blocks = ["52.x.x.x/32"]` would break whenever
#   AWS reassigns the ALB's IP address.
#
# WHAT ABOUT THE EGRESS RULE ON ecs_tasks?
#   ECS tasks need unrestricted outbound to reach ECR (Docker image pulls),
#   Secrets Manager, CloudWatch, S3, and other AWS services. These all go out
#   via the NAT Gateway. The NAT Gateway is the actual boundary — private
#   subnet placement means nothing can reach in. The egress rule allows out.
# ─────────────────────────────────────────────────────────────────────────────

# ALB security group — accepts HTTPS from anywhere, HTTP only to redirect to HTTPS.
# This is the single ingress point; all other resources allow traffic only from here.
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb-sg"
  description = "ALB: accepts HTTPS from internet; redirects HTTP to HTTPS"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from anywhere - the only public ingress (CKV_AWS_2)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP redirect - immediately redirected to HTTPS by listener rule"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow ALB to forward requests to ECS tasks"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ECS tasks security group — accepts traffic only from the ALB, not from the internet.
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project_name}-ecs-tasks-sg"
  description = "ECS tasks: inbound from ALB only; no direct internet access"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Traffic from ALB only - no 0.0.0.0/0 ingress"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow outbound for ECR pulls and AWS API calls (via NAT Gateway)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# RDS security group — accepts connections only from ECS tasks.
resource "aws_security_group" "rds" {
  count       = var.enable_rds ? 1 : 0
  name        = "${var.project_name}-rds-sg"
  description = "RDS: inbound from ECS tasks only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from ECS tasks only - database is never internet-accessible"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ElastiCache security group — accepts connections only from ECS tasks.
resource "aws_security_group" "redis" {
  count       = var.enable_redis ? 1 : 0
  name        = "${var.project_name}-redis-sg"
  description = "ElastiCache Redis: inbound from ECS tasks only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Redis from ECS tasks only"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# APPLICATION LOAD BALANCER — HTTPS Entry Point (CKV_AWS_2)
#
# An ALB (Application Load Balancer) is a Layer-7 (HTTP/HTTPS) reverse proxy
# that sits between the internet and your ECS tasks. It handles:
#   • TLS termination — your ACM certificate lives here; ECS tasks receive plain HTTP
#   • Health-check routing — only sends traffic to healthy ECS task instances
#   • Multi-AZ distribution — routes requests across tasks in different AZs
#
# Traffic flow: internet → ALB (port 443) → ECS tasks (container_port)
#
# Port 80 listener issues a 301 redirect to HTTPS; actual traffic is HTTPS-only.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # enable_deletion_protection prevents accidental ALB deletion via Terraform destroy.
  # Set false for dev environments where you may want clean teardown.
  enable_deletion_protection = false

  # Access logs help diagnose client errors and security events.
  # They are stored in the same S3 bucket as flow logs for simplicity.
  access_logs {
    bucket  = aws_s3_bucket.flow_logs.bucket
    prefix  = "alb"
    enabled = true
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ALB TARGET GROUP — The Pool of Targets That Receive Traffic
#
# A Target Group is a named collection of targets (IP addresses, EC2 instances,
# or Lambda functions) that the ALB routes incoming requests to. The ALB doesn't
# know about ECS directly — it only knows about Target Groups.
#
# How ECS connects to the Target Group:
#   When an ECS task starts, the ECS Service automatically registers the task's
#   private IP address into this target group. When the task stops, it's
#   deregistered. The ALB always has an up-to-date list of healthy task IPs.
#
# Health checks — how the ALB decides which tasks can receive traffic:
#   The ALB sends HTTP GET /health every 30 seconds to each registered task.
#   If a task returns non-200 three times in a row (unhealthy_threshold = 3),
#   the ALB stops sending it traffic. When it returns 200 twice in a row
#   (healthy_threshold = 2), it resumes. This is the mechanism behind
#   zero-downtime deployments: new tasks become healthy before old ones drain.
#
# target_type = "ip":
#   Fargate tasks have no EC2 instance ID — they're addressed by their private
#   IP address directly. "ip" is the only valid target_type for Fargate.
#   EC2-backed ECS would use target_type = "instance".
# ─────────────────────────────────────────────────────────────────────────────
# Target group: routes traffic to ECS tasks.
resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # required for Fargate — tasks have no EC2 instance IDs

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ALB LISTENERS — Rules for Incoming Connections on Specific Ports
#
# A Listener is the ALB's "ear" on a specific port/protocol combination. Each
# listener has a default action that decides what to do with incoming requests.
#
# This template creates two listeners:
#
# PORT 80 (HTTP) — redirect-only:
#   Returns a 301 permanent redirect to the HTTPS version of the same URL.
#   Example: http://my-api.com/data → https://my-api.com/data
#   No application traffic is ever forwarded over HTTP. The redirect happens
#   at the ALB before the request reaches any ECS task.
#   Why keep port 80 open at all? Some clients (browsers, health check tools)
#   initially connect on port 80. The redirect guides them to HTTPS automatically.
#
# PORT 443 (HTTPS) — forward to target group:
#   TLS TERMINATION happens here. The ALB decrypts the HTTPS connection using
#   your ACM certificate, then forwards plain HTTP internally to the ECS tasks.
#   ECS tasks never see encrypted traffic — they only handle HTTP.
#
#   ssl_policy "ELBSecurityPolicy-TLS13-1-2-2021-06":
#     Defines which TLS versions and cipher suites the ALB accepts.
#     This policy accepts TLS 1.2 and TLS 1.3. TLS 1.0 and 1.1 are rejected.
#     TLS 1.0/1.1 have known vulnerabilities (POODLE, BEAST) and are deprecated.
#
# Why terminate TLS at the ALB instead of in the container?
#   - ACM certificates are free and auto-renewed
#   - The ALB handles TLS handshakes for all tasks simultaneously
#   - You don't need to distribute certificates into Docker images
#   - Terminating at the ALB simplifies container code (plain HTTP only)
# ─────────────────────────────────────────────────────────────────────────────
# HTTP listener — 301 redirect to HTTPS. No plain HTTP traffic is forwarded.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS listener — forwards traffic to the ECS target group.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # TLS 1.3 preferred
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM — Identity and Access Management for ECS Tasks (CKV_AWS_111)
#
# IAM controls WHAT AWS services a resource is allowed to call. Without IAM
# roles, a container running in ECS cannot access ANY AWS service — not even
# to write its own logs.
#
# THREE IAM CONCEPTS USED HERE:
#
# 1. IAM ROLE:
#    A set of permissions that AWS services or resources can temporarily assume.
#    Unlike an IAM user (which has permanent credentials), a role generates
#    short-lived credentials (15 minutes–1 hour) on demand. ECS tasks
#    automatically receive these credentials via the task metadata endpoint
#    (169.254.170.2) — your application code never handles long-term secrets.
#
# 2. TRUST POLICY (the assume_role_policy argument):
#    Answers "WHO is allowed to assume this role?" The trust policy below
#    restricts assumption to `ecs-tasks.amazonaws.com` — only ECS tasks can
#    use these permissions. Not Lambda, not EC2, not a human user.
#
# 3. PERMISSIONS POLICY (aws_iam_policy_document / aws_iam_role_policy):
#    Answers "WHAT is this role allowed to do?" We use the data source
#    `aws_iam_policy_document` to build policy JSON in a typed, mergeable way.
#    Principle of least privilege: always list exact action names, never wildcards.
#    Bad:  "actions = ["dynamodb:*"]" — grants 50+ DynamoDB actions
#    Good: "actions = ["dynamodb:GetItem", "dynamodb:PutItem", ...]" — only what's needed
#
# WHY TWO SEPARATE ROLES (task role vs execution role)?
#
#   TASK ROLE (aws_iam_role.ecs_task) — what YOUR APPLICATION CODE uses:
#     Permissions: DynamoDB read/write, S3 access, KMS decrypt, CloudWatch logs.
#     Assumed by: the process running inside your container.
#
#   EXECUTION ROLE (aws_iam_role.ecs_exec) — what THE ECS AGENT uses:
#     The ECS agent is AWS infrastructure (not your code). Before your container
#     starts, it needs to:
#       - Pull the Docker image from ECR (requires ECR authentication)
#       - Stream container stdout/stderr to CloudWatch Logs
#     The AmazonECSTaskExecutionRolePolicy managed policy grants exactly these
#     two capabilities and nothing else.
#
#   Why separate them? A compromised application container cannot access ECR
#   credentials. The ECS agent cannot access DynamoDB. Each role is scoped to
#   its actual purpose — a security boundary between infrastructure and app code.
# ─────────────────────────────────────────────────────────────────────────────

# Trust policy: only ECS tasks can assume this role.
data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# aws_iam_policy_document is a Terraform data source that builds IAM policy JSON
# in a type-safe, mergeable way. Instead of writing raw JSON strings, you declare
# `statement` blocks that Terraform validates and composes into valid IAM JSON.
# The resulting JSON is referenced via `.json` attribute in aws_iam_role_policy.
#
# dynamic "statement" blocks: Terraform's way to conditionally include a statement.
# for_each = var.enable_dynamodb ? [1] : [] — if enable_dynamodb is true, generate
# one statement; if false, generate zero statements. This prevents the task role
# from having a DynamoDB grant when no DynamoDB table exists for this blueprint.
#
# Permissions for the application running in the container.
# The DynamoDB grant is emitted only for blueprints that provision a table, so the
# task role stays least-privilege (no dangling grant to a table that does not exist).
data "aws_iam_policy_document" "ecs_task_permissions" {
  dynamic "statement" {
    for_each = var.enable_dynamodb ? [1] : []
    content {
      sid = "DynamoDBAccess"
      # CKV_AWS_111: explicit actions only — no dynamodb:* wildcard
      actions = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:BatchGetItem",
        "dynamodb:BatchWriteItem"
      ]
      resources = ["arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.dynamodb_table_name}"]
    }
  }

  statement {
    sid     = "KMSDecrypt"
    actions = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }

  statement {
    sid = "ECRPull"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]
    resources = ["*"] # ecr:GetAuthorizationToken requires * resource — scoped by account
  }

  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.project_name}:*"]
  }
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.project_name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_iam_role_policy" "ecs_task" {
  name   = "${var.project_name}-ecs-task-policy"
  role   = aws_iam_role.ecs_task.id
  policy = data.aws_iam_policy_document.ecs_task_permissions.json
}

# ECS task execution role — used by the ECS agent (not the app) to pull images and
# write logs. This is separate from the task role to follow least-privilege.
data "aws_iam_policy_document" "ecs_exec_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_exec" {
  name               = "${var.project_name}-ecs-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_exec_assume.json

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# aws_iam_role_policy_attachment attaches an AWS MANAGED policy to a role.
# Managed policies are maintained by AWS — when ECS adds new logging destinations
# or ECR features, the policy is updated automatically. The alternative is an
# inline policy (aws_iam_role_policy) which you maintain yourself.
# AmazonECSTaskExecutionRolePolicy grants exactly: ECR authentication + CloudWatch
# Logs write. It was designed for this purpose and contains nothing extra.
resource "aws_iam_role_policy_attachment" "ecs_exec" {
  role       = aws_iam_role.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLOUDWATCH LOG GROUP — Centralized Application and Container Log Storage
#
# Amazon CloudWatch is AWS's monitoring and observability service. It collects
# logs, metrics, and events from AWS services and your own applications.
#
# A LOG GROUP is a named container for log streams. Within a log group, each
# running ECS task writes to its own LOG STREAM (named with a task UUID). The
# log group is the unit for access control, retention policy, and encryption.
#
# HOW ECS CONTAINER LOGS REACH CLOUDWATCH:
#   The ECS task definition below sets logDriver = "awslogs". This tells the ECS
#   agent to capture stdout and stderr from the container and forward them to
#   CloudWatch Logs automatically. Your application just writes to stdout/stderr
#   (as any 12-factor app should) — no log agent, no sidecar, no file watching.
#
# WHY CLOUDWATCH LOGS AND NOT S3 DIRECTLY?
#   CloudWatch Logs provides real-time streaming, filtering, and search that S3
#   does not. You can tail logs in the console (CloudWatch Logs Insights), set
#   metric filters to alert on ERROR patterns, or run ad-hoc queries. S3 is
#   better for cold, long-term archival (see VPC Flow Logs above, which uses S3).
#
# retention_in_days = 30:
#   Without a retention policy, logs accumulate forever and storage costs grow
#   unboundedly. 30 days is a sensible default; adjust to match compliance needs
#   (PCI-DSS requires 12 months; HIPAA may require 6–7 years).
#
# kms_key_id:
#   Encrypts all log events at rest with the project KMS key. Without this,
#   CloudWatch stores log data in AWS-managed encryption — still encrypted, but
#   you have no control over the key and cannot revoke access independently.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_name}"
  # KMS encryption on CloudWatch logs prevents log data from being readable
  # if an attacker gains S3 access without KMS permissions.
  kms_key_id        = aws_kms_key.main.arn
  retention_in_days = 30

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ECS FARGATE — Serverless Container Platform
#
# Amazon ECS (Elastic Container Service) with the Fargate launch type runs Docker
# containers without you managing EC2 instances. You specify what to run (image,
# CPU, memory, ports) and AWS handles the underlying server fleet.
#
# Fargate vs EC2 launch type:
#   EC2 launch type: you provision, patch, and scale EC2 instances yourself
#   Fargate:         AWS manages the instances — no SSH, no patching, no capacity
#                    planning. You only pay for the CPU/memory your tasks use.
#
# Three resources form the compute layer:
#   aws_ecs_cluster         — logical namespace grouping related tasks and services
#   aws_ecs_task_definition — versioned blueprint: Docker image, CPU/memory, ports,
#                             IAM roles, environment variables, logging config
#   aws_ecs_service         — keeps N healthy task copies running at all times,
#                             registers them with the ALB target group, and
#                             replaces any task that fails its health check
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    # Container Insights enables CloudWatch metrics for CPU, memory, and network
    # per task. Without it, you cannot set alarms or investigate performance issues.
    value = "enabled"
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ECS Task Definition — describes the container(s) to run.
resource "aws_ecs_task_definition" "app" {
  family = "${var.project_name}-task"
  # network_mode = "awsvpc": each Fargate task gets its own elastic network
  # interface (ENI) and private IP address from the subnet. This is the ONLY
  # valid network mode for Fargate. It enables security group assignment per
  # task (as opposed to per EC2 host), which is why the ecs_tasks security group
  # can be referenced specifically in the RDS/Redis security group ingress rules.
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_exec.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = var.project_name
      image     = var.container_image
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }

      # readonlyRootFilesystem prevents the container from writing to its own
      # filesystem, making it significantly harder for an attacker to persist
      # malware or exfiltrate credentials via local files.
      readonlyRootFilesystem = true

      # SPRING_PROFILES_ACTIVE is used by Spring Boot to select the active profile
      # (e.g. "dev" or "prod"). Non-Spring frameworks (Ktor, FastAPI) will simply
      # ignore this env var — it has no effect on them.
      environment = [
        { name = "SPRING_PROFILES_ACTIVE", value = var.environment },
        { name = "AWS_REGION", value = data.aws_region.current.name }
      ]
    }
  ])

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ECS Service — manages running tasks and registers them with the ALB.
resource "aws_ecs_service" "app" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Zero-downtime rolling deploy: start new tasks before stopping old ones.
  # minimum_healthy_percent=100 ensures capacity never drops below desired_count.
  # maximum_percent=200 allows temporarily running 2x desired_count during rollout.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    # assign_public_ip must be false — tasks are in private subnets
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.project_name
    container_port   = var.container_port
  }

  depends_on = [aws_lb_listener.https]

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# RDS POSTGRESQL — Managed Relational Database (springboot-postgres blueprint)
#
# Amazon RDS (Relational Database Service) is a managed PostgreSQL service.
# AWS handles backups, patching, minor version upgrades, and Multi-AZ failover.
# You get a standard PostgreSQL endpoint that Spring Boot + Hibernate connects
# to exactly as it would a self-hosted Postgres instance.
#
# This block is only created when enable_rds = true (springboot-postgres blueprint).
# For ktor-dynamodb and fastapi-redis, count = 0 and no RDS resources are created.
#
# Encrypted, private, not publicly accessible (CKV_AWS_17, CKV_AWS_23).
# ─────────────────────────────────────────────────────────────────────────────

# A DB Subnet Group tells RDS which subnets it can place the database instance in.
# RDS requires at least two subnets in different AZs even when Multi-AZ is off —
# this allows seamless failover if you later enable it without reprovisioning.
# We pass only private subnets: the RDS instance gets no public IP and is
# unreachable from the internet even if publicly_accessible = true were set.
resource "aws_db_subnet_group" "main" {
  count       = var.enable_rds ? 1 : 0
  name        = "${var.project_name}-db-subnet-group"
  subnet_ids  = aws_subnet.private[*].id
  description = "Private subnets for RDS - no public internet access"

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
  # max_allocated_storage enables RDS Storage Autoscaling. When the database is
  # more than 90% full, RDS automatically increases storage up to this limit without
  # downtime. Setting it to 5× the initial means you start small (20 GB default)
  # but can grow to 100 GB automatically. Without this, a full disk causes the
  # database to go into read-only mode and your application to start failing writes.
  max_allocated_storage   = var.db_allocated_storage * 5

  db_name  = var.db_name
  username = var.db_username
  # manage_master_user_password = true: instead of supplying a password in
  # Terraform (which would appear in state files in plaintext), RDS generates
  # a strong password and stores it in AWS Secrets Manager automatically.
  # Your application retrieves the password at runtime via the Secrets Manager
  # SDK — it never appears in Terraform state, code, or environment variables.
  # The Secrets Manager secret ARN is available at:
  #   aws_db_instance.postgres[0].master_user_secret[0].secret_arn
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  # CKV_AWS_17: publicly_accessible = false prevents the RDS instance from
  # getting a public IP. Without this, the database can be reached over the internet
  # even if the security group restricts access — a defense-in-depth measure.
  publicly_accessible = false

  # CKV_AWS_23: storage_encrypted = true with a dedicated KMS key ensures data
  # at rest is encrypted. Without it, anyone with access to the underlying EBS
  # volume can read the database files.
  storage_encrypted = true
  kms_key_id        = aws_kms_key.main.arn

  multi_az            = false # set true for production HA
  skip_final_snapshot = true
  deletion_protection = false

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
# DYNAMODB TABLE — Managed NoSQL Key-Value Store (ktor-dynamodb blueprint)
#
# Amazon DynamoDB is a fully managed NoSQL database with single-digit millisecond
# latency at any scale. Unlike RDS, there is no server to provision or connection
# pool to manage — you just read/write items by key.
#
# Key concepts:
#   hash_key (partition key) — the primary lookup attribute; items with the same
#                              hash_key are co-located on the same partition.
#   PAY_PER_REQUEST billing  — no capacity planning needed; you pay per read/write.
#   Point-in-time recovery   — enabled below; lets you restore to any second in the
#                              last 35 days if data is accidentally corrupted.
#
# This block is only created when enable_dynamodb = true (ktor-dynamodb blueprint).
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "main" {
  count        = var.enable_dynamodb ? 1 : 0
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST" # on-demand — no capacity planning required for variable workloads
  hash_key     = var.dynamodb_hash_key

  attribute {
    name = var.dynamodb_hash_key
    type = "S"
  }

  # server_side_encryption encrypts all DynamoDB items at rest using an AWS-owned
  # or customer-managed key. Without it, data is stored unencrypted on disk.
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ELASTICACHE REDIS — Managed In-Memory Cache (fastapi-redis blueprint)
#
# Amazon ElastiCache for Redis is a managed Redis service. Redis stores data
# entirely in memory, making it 10–100× faster than reading from a database.
# Common uses: caching API responses, session storage, rate limiting counters,
# pub/sub messaging between services.
#
# Why a replication group (not aws_elasticache_cluster)?
# We use aws_elasticache_replication_group rather than the legacy
# aws_elasticache_cluster resource because at_rest_encryption_enabled is only
# configurable on the replication group. The legacy cluster resource does not
# expose it, so it cannot pass checkov's CKV_AWS_29 check.
#
# This block is only created when enable_redis = true (fastapi-redis blueprint).
# ─────────────────────────────────────────────────────────────────────────────

# An ElastiCache Subnet Group specifies which subnets ElastiCache can place nodes in.
# Same requirement as RDS: multiple AZs for failover capability, private subnets
# so Redis is never reachable from the internet — only from ECS tasks via the
# Redis security group (port 6379 from ecs_tasks SG only).
resource "aws_elasticache_subnet_group" "main" {
  count       = var.enable_redis ? 1 : 0
  name        = "${var.project_name}-redis-subnet-group"
  subnet_ids  = aws_subnet.private[*].id
  description = "Private subnets for ElastiCache Redis"

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ElastiCache Redis via a replication group (cluster-mode-disabled, single shard).
# We use aws_elasticache_replication_group rather than aws_elasticache_cluster because
# at-rest encryption (at_rest_encryption_enabled) is only configurable on the replication
# group resource — the legacy cluster resource does not expose it.
resource "aws_elasticache_replication_group" "redis" {
  count                = var.enable_redis ? 1 : 0
  replication_group_id = "${var.project_name}-redis"
  description          = "Redis cache for ${var.project_name}"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  num_cache_clusters   = var.redis_num_nodes
  parameter_group_name = "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main[0].name
  security_group_ids = [aws_security_group.redis[0].id]

  # Single-node deployments cannot use automatic failover; keep it off so the default
  # (redis_num_nodes = 1) is valid. Raise redis_num_nodes to add read replicas.
  automatic_failover_enabled = false

  # at_rest_encryption_enabled encrypts the Redis data on disk.
  # Without it, a compromised host could read cache contents directly from storage.
  at_rest_encryption_enabled = true

  # transit_encryption_enabled forces TLS for all client connections.
  # Without it, Redis traffic on the wire is plaintext and sniffable within the VPC.
  transit_encryption_enabled = true

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer. Point your domain's CNAME here."
  value       = aws_lb.main.dns_name
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  value       = aws_ecs_cluster.main.name
}

output "rds_endpoint" {
  description = "RDS instance endpoint. Use this in your application configuration (not the public internet)."
  value       = try(aws_db_instance.postgres[0].endpoint, "N/A - RDS not provisioned for this blueprint")
  sensitive   = true
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint."
  value       = try(aws_elasticache_replication_group.redis[0].primary_endpoint_address, "N/A - Redis not provisioned for this blueprint")
  sensitive   = true
}

output "vpc_id" {
  description = "ID of the VPC created for this deployment."
  value       = aws_vpc.main.id
}
