# main.tf — ECS Fargate template family
# Covers springboot-postgres, ktor-dynamodb, and fastapi-redis blueprints.
# This file IS the reference implementation of Gentepede security best practices.
# providers.tf is NOT here — it is written at runtime by InfrastructureService.

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
  cidr_block           = "10.0.0.0/16"
  # enable_dns_hostnames is required for RDS and ElastiCache endpoint resolution
  # inside the VPC. Without it, DNS names returned by AWS would not resolve.
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# Internet Gateway — the only path for traffic entering/leaving the VPC.
# Public subnets route 0.0.0.0/0 through this; private subnets do not.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

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
# VPC Flow Logs — Network Traffic Audit Trail (CKV_AWS_66)
# Flow logs capture metadata for all IP traffic entering/leaving the VPC.
# Without them, a security incident cannot be investigated retroactively.
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
# SECURITY GROUPS
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
# APPLICATION LOAD BALANCER — HTTPS Termination (CKV_AWS_2)
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
# IAM — ECS Task Role (CKV_AWS_111)
# Explicit allow-list of AWS actions. No wildcard (*) actions.
# The task role is what the application code inside the container uses to call AWS.
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

resource "aws_iam_role_policy_attachment" "ecs_exec" {
  role       = aws_iam_role.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLOUDWATCH LOG GROUP — ECS Container Logs
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
# ECS CLUSTER
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
  family                   = "${var.project_name}-task"
  network_mode             = "awsvpc" # required for Fargate
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
# RDS POSTGRESQL — Encrypted, Private, Not Publicly Accessible (CKV_AWS_17, CKV_AWS_23)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  count      = var.enable_rds ? 1 : 0
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
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
  max_allocated_storage   = var.db_allocated_storage * 5 # autoscale up to 5x initial

  db_name  = var.db_name
  username = var.db_username
  # password is intentionally omitted — use aws_db_instance password_secret_arn
  # or set via a Secrets Manager reference post-provisioning. Never hardcode.
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
# DYNAMODB TABLE — On-demand, encrypted (ktor-dynamodb blueprint)
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
# ELASTICACHE REDIS — Encrypted at rest and in transit (fastapi-redis blueprint)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_elasticache_subnet_group" "main" {
  count      = var.enable_redis ? 1 : 0
  name       = "${var.project_name}-redis-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  description = "Private subnets for ElastiCache Redis"

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_elasticache_cluster" "redis" {
  count                = var.enable_redis ? 1 : 0
  cluster_id           = "${var.project_name}-redis"
  engine               = "redis"
  node_type            = var.redis_node_type
  num_cache_nodes      = var.redis_num_nodes
  parameter_group_name = "default.redis7"
  engine_version       = "7.1"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.main[0].name
  security_group_ids = [aws_security_group.redis[0].id]

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
  value       = try(aws_db_instance.postgres[0].endpoint, "N/A — RDS not provisioned for this blueprint")
  sensitive   = true
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint."
  value       = try(aws_elasticache_cluster.redis[0].cache_nodes[0].address, "N/A — Redis not provisioned for this blueprint")
  sensitive   = true
}

output "vpc_id" {
  description = "ID of the VPC created for this deployment."
  value       = aws_vpc.main.id
}
