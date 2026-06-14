# main.tf — Lambda template family
# Covers the nodejs-s3 blueprint: Lambda + API Gateway + S3 + CloudFront.
# providers.tf is NOT here — written at runtime by InfrastructureService.

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────────────────────────
# KMS KEY — Project encryption key for S3 and Lambda environment variables
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
# S3 BUCKET — Application storage (CKV_AWS_19, CKV_AWS_21)
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "app" {
  bucket = var.s3_bucket_name

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# CKV_AWS_21: versioning enabled — protects against accidental object deletion
# and enables point-in-time recovery of any object.
resource "aws_s3_bucket_versioning" "app" {
  bucket = aws_s3_bucket.app.id
  versioning_configuration {
    status = "Enabled"
  }
}

# CKV_AWS_19: server-side encryption with a customer-managed KMS key.
# Without this, S3 objects are stored unencrypted (or with AWS-managed keys
# that cannot be independently audited or revoked).
resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  bucket = aws_s3_bucket.app.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    # bucket_key_enabled reduces KMS API calls and cost by using a per-bucket
    # data encryption key derived from the CMK.
    bucket_key_enabled = true
  }
}

# Block all public access — four flags together prevent every public-access pathway:
# ACLs, bucket policies, cross-account access, and public object reads.
resource "aws_s3_bucket_public_access_block" "app" {
  bucket                  = aws_s3_bucket.app.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle rule: move objects to Glacier after 90 days to control storage costs
# while retaining long-term audit data.
resource "aws_s3_bucket_lifecycle_configuration" "app" {
  bucket = aws_s3_bucket.app.id

  rule {
    id     = "archive-old-objects"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# CLOUDWATCH LOG GROUP — Lambda function logs
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}"
  kms_key_id        = aws_kms_key.main.arn
  retention_in_days = 30

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# IAM — Lambda Execution Role (CKV_AWS_111)
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    # Scope to the specific log group — not logs:* on all resources.
    resources = [
      "${aws_cloudwatch_log_group.lambda.arn}:*"
    ]
  }

  statement {
    sid = "S3Access"
    # CKV_AWS_111: explicit S3 actions — no s3:* wildcard
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.app.arn,
      "${aws_s3_bucket.app.arn}/*"
    ]
  }

  statement {
    sid     = "KMSDecrypt"
    actions = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.project_name}-lambda-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

# ─────────────────────────────────────────────────────────────────────────────
# LAMBDA FUNCTION
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lambda_function" "app" {
  function_name = "${var.project_name}-function"
  filename      = var.lambda_zip_path
  handler       = var.lambda_handler
  runtime       = var.lambda_runtime
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory
  role          = aws_iam_role.lambda.arn

  # source_code_hash triggers a function update whenever the ZIP content changes.
  # Without it, Terraform does not redeploy even when code is updated.
  source_code_hash = filebase64sha256(var.lambda_zip_path)

  # kms_key_arn encrypts Lambda environment variables at rest.
  # Without it, environment variables (which may contain secrets) are stored in plaintext.
  kms_key_arn = aws_kms_key.main.arn

  environment {
    variables = {
      S3_BUCKET_NAME = aws_s3_bucket.app.bucket
      AWS_ACCOUNT_ID = data.aws_caller_identity.current.account_id
      ENVIRONMENT    = var.environment
    }
  }

  # reserved_concurrent_executions = -1 means unreserved (uses account pool).
  # Set a positive integer to cap concurrency and prevent runaway invocations
  # from exhausting account-level Lambda concurrency.
  reserved_concurrent_executions = -1

  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# API GATEWAY — HTTP API (v2)
# HTTP API is lower cost and lower latency than REST API for simple proxy integrations.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"] # tighten per environment — allow specific origins in prod
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 3600
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.app.invoke_arn
  integration_method = "POST"

  # payload_format_version 2.0 is the modern Lambda proxy format.
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.lambda.arn
    # format is a required argument whenever access_log_settings is present.
    # This JSON access-log format captures the standard request fields. The
    # "$context.*" tokens are API Gateway variables, not Terraform interpolations
    # (Terraform only interpolates "${...}"), so they pass through literally.
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# Grant API Gateway permission to invoke the Lambda function.
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLOUDFRONT DISTRIBUTION — CDN with HTTPS enforcement
# CloudFront terminates TLS at the edge and forwards requests to API Gateway.
# CKV_AWS_2: HTTPS-only distribution, no plaintext HTTP forwarding.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  price_class         = var.cloudfront_price_class
  comment             = "${var.project_name} distribution"
  default_root_object = "index.html"

  origin {
    domain_name = replace(aws_apigatewayv2_api.main.api_endpoint, "https://", "")
    origin_id   = "api-gateway"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only" # never downgrade to HTTP toward origin
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "api-gateway"
    viewer_protocol_policy = "redirect-to-https" # force HTTPS for all viewers

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Content-Type"]
      cookies {
        forward = "none"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # cloudfront_default_certificate uses the CloudFront domain.
    # Replace with acm_certificate_arn for a custom domain.
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────────────────────────────────────────────

output "cloudfront_domain_name" {
  description = "CloudFront distribution domain name. Point your domain's CNAME here."
  value       = aws_cloudfront_distribution.main.domain_name
}

output "api_gateway_endpoint" {
  description = "Direct API Gateway endpoint (use CloudFront in production)."
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "lambda_function_name" {
  description = "Name of the deployed Lambda function."
  value       = aws_lambda_function.app.function_name
}

output "s3_bucket_name" {
  description = "Name of the S3 storage bucket."
  value       = aws_s3_bucket.app.bucket
}
