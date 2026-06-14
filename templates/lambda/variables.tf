# variables.tf — Lambda template family
# Inputs for the nodejs-s3 blueprint: Lambda + API Gateway + S3 + CloudFront.

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

variable "lambda_zip_path" {
  description = "Local path to the Lambda deployment ZIP file containing Node.js handler code."
  type        = string
}

variable "lambda_handler" {
  description = "Handler entrypoint in the form 'filename.exportedFunction', e.g. 'index.handler'."
  type        = string
  default     = "index.handler"
}

variable "lambda_runtime" {
  description = "Lambda runtime identifier. Use nodejs20.x for Node.js 20 LTS."
  type        = string
  default     = "nodejs20.x"
}

variable "lambda_timeout" {
  description = "Maximum Lambda execution time in seconds (1–900). API Gateway hard limit is 29s."
  type        = number
  default     = 30
}

variable "lambda_memory" {
  description = "Lambda memory allocation in MiB (128–10240). CPU scales proportionally with memory."
  type        = number
  default     = 256
}

variable "s3_bucket_name" {
  description = "Name for the S3 storage bucket. Must be globally unique across all AWS accounts."
  type        = string
}

variable "cloudfront_price_class" {
  description = "CloudFront edge location set: PriceClass_100 (US/EU), PriceClass_200 (+ Asia/Africa), PriceClass_All."
  type        = string
  default     = "PriceClass_100"
}
