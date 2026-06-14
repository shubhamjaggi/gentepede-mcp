# variables.tf — EKS template family
# Inputs for springboot-eks and nodejs-eks blueprints.

variable "project_name" {
  description = "Unique slug for all resources. Used in resource names and tags."
  type        = string
}

variable "aws_region" {
  description = "AWS region where the EKS cluster and all resources are created."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI named profile (PRODUCTION only)."
  type        = string
  default     = "default"
}

variable "environment" {
  description = "Environment name for tagging (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "eks_version" {
  description = "Kubernetes version for the EKS control plane. Check AWS docs for supported versions."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes. t3.medium minimum for production."
  type        = string
  default     = "t3.medium"
}

variable "node_count" {
  description = "Desired number of EKS worker nodes."
  type        = number
  default     = 2
}

variable "certificate_arn" {
  description = "ACM certificate ARN for the ALB Ingress Controller HTTPS listener."
  type        = string
}

# ─── RDS (springboot-eks) ─────────────────────────────────────────────────────

# Gentepede sets this in terraform.tfvars from the blueprint's declared awsResources:
# springboot-eks declares RDS_POSTGRES (true); nodejs-eks does not (false), so the
# shared EKS template provisions a database only when the blueprint asks for one.
variable "enable_rds" {
  description = "Provision the RDS PostgreSQL data tier (springboot-eks blueprint)."
  type        = bool
  default     = false
}

variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "PostgreSQL master username (not for application connection strings)."
  type        = string
  default     = "dbadmin"
}

variable "db_instance_class" {
  description = "RDS instance type."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GB."
  type        = number
  default     = 20
}

# ─── S3 + CloudFront (nodejs-eks) ─────────────────────────────────────────────

variable "s3_bucket_name" {
  description = "Globally unique S3 bucket name (nodejs-eks blueprint)."
  type        = string
  default     = ""
}

variable "cloudfront_price_class" {
  description = "CloudFront price class for the nodejs-eks blueprint."
  type        = string
  default     = "PriceClass_100"
}
