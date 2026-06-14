# variables.tf — ECS Fargate template family
# Defines all inputs accepted by main.tf for ECS-based blueprints.
# Covers springboot-postgres, ktor-dynamodb, and fastapi-redis.

variable "project_name" {
  description = "Unique slug for all resources in this deployment. Used in resource names and tags."
  type        = string
}

variable "aws_region" {
  description = "AWS region where resources are created."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI named profile. Used by the PRODUCTION provider; ignored in LOCAL mode."
  type        = string
  default     = "default"
}

variable "environment" {
  description = "Environment name for tagging (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "container_image" {
  description = "Full ECR image URI including tag, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/myapp:1.0.0"
  type        = string
}

variable "container_port" {
  description = "TCP port the container listens on. Spring Boot=8080, FastAPI=8000."
  type        = number
  default     = 8080
}

variable "task_cpu" {
  description = "ECS Fargate task CPU units. Valid values: 256, 512, 1024, 2048, 4096."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "ECS Fargate task memory in MiB. Must be compatible with task_cpu."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Number of running ECS task instances. Set >= 2 for high availability."
  type        = number
  default     = 2
}

variable "certificate_arn" {
  description = "ARN of an ACM certificate for the ALB HTTPS listener. Must exist before apply."
  type        = string
}

# ─── RDS-specific (springboot-postgres) ───────────────────────────────────────

variable "db_name" {
  description = "Name of the PostgreSQL database created on the RDS instance."
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username for the RDS instance. NOT used in application connection strings — create a separate app user post-provisioning."
  type        = string
  default     = "dbadmin"
}

variable "db_instance_class" {
  description = "RDS instance size. Minimum db.t3.micro for dev; db.r6g.large for production."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GB. RDS autoscales beyond this if max_allocated_storage is set."
  type        = number
  default     = 20
}

# ─── DynamoDB-specific (ktor-dynamodb) ────────────────────────────────────────

variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table. Must be unique within the AWS account and region."
  type        = string
  default     = "app-table"
}

variable "dynamodb_hash_key" {
  description = "Name of the DynamoDB partition key attribute."
  type        = string
  default     = "id"
}

# ─── ElastiCache-specific (fastapi-redis) ─────────────────────────────────────

variable "redis_node_type" {
  description = "ElastiCache node instance type. Minimum cache.t3.micro for dev."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_nodes" {
  description = "Number of ElastiCache nodes. Set 1 for dev, >= 2 for cluster mode in prod."
  type        = number
  default     = 1
}

# ─── Data-tier toggles ────────────────────────────────────────────────────────
# Gentepede sets these in terraform.tfvars from each blueprint's declared
# awsResources, so a single shared ECS template provisions only the data tier
# that blueprint actually needs. All default to false; the generated tfvars
# enables exactly the one(s) the blueprint declares. See InfrastructureService.buildTfvarsContent.

variable "enable_rds" {
  description = "Provision the RDS PostgreSQL data tier (springboot-postgres blueprint)."
  type        = bool
  default     = false
}

variable "enable_dynamodb" {
  description = "Provision the DynamoDB table (ktor-dynamodb blueprint)."
  type        = bool
  default     = false
}

variable "enable_redis" {
  description = "Provision the ElastiCache Redis cluster (fastapi-redis blueprint)."
  type        = bool
  default     = false
}
