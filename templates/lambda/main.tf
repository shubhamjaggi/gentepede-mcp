# main.tf — Lambda template family
# Covers the nodejs-s3 blueprint: Lambda + API Gateway + S3 + CloudFront.
# providers.tf is NOT here — written at runtime by InfrastructureService.

# ─────────────────────────────────────────────────────────────────────────────
# HOW RESOURCE GATING WORKS (Lambda family: nodejs-s3)
#
# The Lambda template family currently covers one blueprint: nodejs-s3.
# Unlike the ECS and EKS families, there are NO conditional boolean toggles here.
# Every resource in this file is ALWAYS provisioned — the nodejs-s3 blueprint
# always deploys Lambda + API Gateway + S3 + CloudFront + KMS together.
#
# Why no toggles? Because serverless Node.js APIs have a tightly coupled stack:
#   Lambda         — the compute (runs the function code)
#   API Gateway    — the HTTPS trigger (exposes Lambda to the internet)
#   S3             — persistent object storage for the function
#   CloudFront     — CDN and HTTPS termination in front of API Gateway
#   KMS            — encryption key for S3 objects and Lambda env vars
#
# These five services are inseparable for a production serverless API. There is
# no useful variant of nodejs-s3 that omits, say, S3 but keeps Lambda.
#
# InfrastructureService.injectDataTierToggles() leaves the lambda template
# family untouched — no boolean flags are injected into terraform.tfvars.
#
# Why Node.js + Lambda instead of ECS Fargate?
#   ECS Fargate: long-running server process, always-on, billed per second running
#   Lambda:      event-driven, runs only when invoked, billed per invocation.
#                Ideal for APIs with variable or low traffic (< 1M req/month is
#                often cheaper than a running ECS task).
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# S3 LIFECYCLE RULE — Automatic Cost-Reduction Through Storage Tiering
#
# S3 offers several storage classes with different cost/latency trade-offs:
#
#   STANDARD         ~$0.023/GB/mo  — immediate access, low latency
#   STANDARD_IA      ~$0.0125/GB/mo — infrequent access, retrieval fee applies
#   GLACIER          ~$0.004/GB/mo  — archive storage, retrieval takes 3–5 hours
#   GLACIER_DEEP_ARCHIVE ~$0.00099/GB/mo — coldest storage, 12-hour retrieval
#
# A LIFECYCLE RULE automatically moves objects between storage classes (or
# deletes them) based on age. Without lifecycle rules, all objects stay in
# STANDARD forever and you pay full price even for files no one accesses.
#
# This rule: after 90 days → move to GLACIER
#   Objects uploaded by the Lambda function (logs, user data, generated files)
#   are unlikely to be frequently accessed after 90 days. Moving them to Glacier
#   reduces cost by ~83% with no manual action required.
#
# When to change this:
#   - Increase the transition_days if your use case accesses older objects frequently
#   - Add a second transition to DEEP_ARCHIVE for objects older than 365 days
#   - Add an expiration rule if objects can be deleted after a certain age
#   - If objects must be instantly retrievable indefinitely, remove this rule
# ─────────────────────────────────────────────────────────────────────────────
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
# CLOUDWATCH LOG GROUP — Lambda Function Logs
#
# Amazon CloudWatch Logs stores logs from Lambda functions. When the function
# writes to stdout/stderr (console.log in Node.js), Lambda automatically streams
# those lines to the log group /aws/lambda/<function-name>.
#
# We create this log group explicitly (rather than letting Lambda auto-create it)
# for two reasons:
#   1. KMS encryption: auto-created log groups use AWS-managed keys.
#      Explicitly creating the group lets us attach our project KMS key.
#   2. Retention: auto-created log groups retain logs forever (unbounded cost).
#      Setting retention_in_days = 30 automatically purges logs older than 30 days.
#
# The depends_on in the Lambda function resource ensures this group exists before
# the function starts, preventing a race condition where the first invocation
# tries to log before the group exists.
#
# See the ECS template's CloudWatch Log Group section for the full concept
# explanation of what CloudWatch Logs is and when to use it vs S3.
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
#
# Every Lambda function needs an IAM execution role. AWS assumes this role on
# behalf of the function when it runs. The role controls which AWS services the
# function code is allowed to call.
#
# Trust policy: `lambda.amazonaws.com` — only the Lambda service can assume this
# role. A person or another service cannot use these permissions directly.
#
# This role grants three capabilities (all explicitly listed, no wildcards):
#   CloudWatch Logs: write log events to the specific log group created above
#   S3: read/write/list/delete objects in this specific bucket only
#   KMS: decrypt and generate data keys using this project's KMS key
#
# What this role CANNOT do (by omission):
#   - Access any other S3 bucket
#   - Call DynamoDB, RDS, SNS, SQS, or any other service
#   - Assume other IAM roles
#
# Why use aws_iam_role_policy (inline policy) vs aws_iam_policy + attachment?
#   Inline policies are scoped to one role and deleted with it — no orphaned
#   managed policies. For a project-specific role with no sharing, inline is cleaner.
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
    sid       = "KMSDecrypt"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
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
# AWS LAMBDA — Serverless Function Compute
#
# AWS Lambda runs code without provisioning servers. You upload a ZIP containing
# your Node.js function; Lambda executes it on demand and bills per invocation
# and per 100ms of execution time. Cost approaches zero for low-traffic APIs.
#
# Key concepts for this resource:
#   handler    — the exported function Lambda calls: "index.handler" means the
#                `handler` export in the file `index.js` inside the ZIP
#   runtime    — the execution environment: nodejs20.x = Node.js 20 LTS
#   memory     — RAM in MiB; Lambda CPU scales proportionally with memory
#   timeout    — max execution duration; API Gateway enforces a 29s hard cap
#   cold start — first invocation after idle takes ~100–500ms for Node.js as
#                Lambda boots a new execution environment; warm invocations reuse it
#
# source_code_hash: triggers redeployment whenever the ZIP content changes.
# Without it, Terraform considers the function unchanged even when code updates.
#
# The IAM execution role (aws_iam_role.lambda) controls what AWS services the
# function code can call. It is scoped to: S3 (this bucket only) + CloudWatch
# Logs + KMS decrypt. No other AWS services are reachable from this function.
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

  # ─────────────────────────────────────────────────────────────────────────
  # LAMBDA CONCURRENCY — How Many Simultaneous Invocations Are Allowed
  #
  # Lambda scales horizontally: each concurrent request gets its own execution
  # environment. By default, an AWS account has a concurrency limit of 1000
  # across ALL Lambda functions in the region. A single function under heavy
  # traffic could consume the entire pool, throttling every other function.
  #
  # reserved_concurrent_executions = -1:
  #   "Unreserved" — this function draws from the shared account pool.
  #   -1 means no reservation (not "0 concurrency", which would disable the function).
  #
  # To prevent one function from monopolizing concurrency:
  #   reserved_concurrent_executions = 100
  #   This reserves 100 executions exclusively for this function AND caps it at 100.
  #   If traffic exceeds 100 concurrent requests, Lambda throttles (returns 429)
  #   rather than consuming other functions' capacity.
  #
  # Set a reservation if: this function shares an account with other critical
  # functions, or if you need to guarantee a minimum capacity under traffic spikes.
  # ─────────────────────────────────────────────────────────────────────────
  reserved_concurrent_executions = -1

  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "gentepede-mcp"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS API GATEWAY — HTTP API (v2)
#
# API Gateway creates an HTTPS endpoint that invokes the Lambda function.
# Without it, Lambda cannot receive web traffic — it can only be invoked via
# the AWS SDK/CLI directly.
#
# We use the v2 HTTP API (not the older REST API v1) because:
#   • Lower latency: ~10ms overhead vs ~60ms for REST API
#   • Lower cost: ~$1/million requests vs ~$3.50/million for REST API
#   • Native Lambda integration: payload format 2.0 is simpler and faster
#   • auto_deploy = true: no manual "Create Deployment" step after route changes
#
# Four resources wire the API together:
#   aws_apigatewayv2_api         — the API definition (name, protocol, CORS rules)
#   aws_apigatewayv2_integration — "forward all requests to this Lambda function"
#   aws_apigatewayv2_route       — "$default" catches every unmatched route/method
#   aws_apigatewayv2_stage       — the deployment stage; auto_deploy rebuilds on change
#   aws_lambda_permission        — grants API Gateway permission to invoke the function
#
# HTTP API is lower cost and lower latency than REST API for simple proxy integrations.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"

  # ───────────────────────────────────────────────────────────────────────────
  # CORS (Cross-Origin Resource Sharing) — Browser Security Policy for APIs
  #
  # Browsers enforce the Same-Origin Policy: a web page at https://app.com
  # cannot make JavaScript fetch() calls to https://api.com unless the API
  # explicitly allows it. CORS is the mechanism by which an API declares which
  # origins (other domains) are allowed to call it from a browser.
  #
  # How it works:
  #   1. Browser sends a "preflight" OPTIONS request to the API before the real call
  #   2. API Gateway responds with CORS headers (Access-Control-Allow-*)
  #   3. If the origin, method, and headers match, the browser proceeds with the real call
  #   4. If they don't match, the browser blocks the request — the API is never called
  #
  # allow_origins = ["*"]:
  #   Allows any origin to call this API. Appropriate for truly public APIs.
  #   For production, restrict to your specific frontend domain:
  #   allow_origins = ["https://app.mycompany.com"]
  #
  # allow_methods: the HTTP methods browsers can use (GET, POST, PUT, DELETE, OPTIONS)
  # allow_headers: headers browsers are allowed to include (Content-Type, Authorization)
  # max_age = 3600: browsers cache the preflight result for 1 hour, avoiding
  #   a preflight request before every API call
  #
  # Note: CORS is a BROWSER enforcement. CLI tools (curl, Postman, backend services)
  # are not subject to CORS — only web browser JavaScript is restricted.
  # ───────────────────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────────────────────
# LAMBDA RESOURCE-BASED POLICY — Granting API Gateway Permission to Invoke
#
# Lambda uses TWO types of access control simultaneously:
#
#   1. IAM EXECUTION ROLE (identity-based policy, above):
#      Controls what the Lambda function can DO when it runs — which AWS services
#      it can call (S3, CloudWatch, KMS). This is attached to the function itself.
#
#   2. RESOURCE-BASED POLICY (aws_lambda_permission — this resource):
#      Controls who can INVOKE the Lambda function. Without this, API Gateway
#      would receive "Access Denied" when trying to call the function, even if
#      the integration is correctly configured.
#
# aws_lambda_permission adds a statement to the Lambda function's resource policy:
#   "Allow principal apigateway.amazonaws.com to call lambda:InvokeFunction
#    on this function, but ONLY when the invocation comes from ARN: <this API>/*/*"
#
# The source_arn condition (/*/*) is important:
#   It restricts which API Gateway can invoke this function. Without it, ANY
#   API Gateway in your AWS account could invoke this Lambda — including someone
#   else's accidentally misconfigured API. The /*/*  means: this API, any stage,
#   any route. You can further restrict to specific stages or routes.
#
# Why is this separate from IAM role policies?
#   IAM role policies are attached to identities (roles, users). Resource-based
#   policies are attached to resources (Lambda functions, S3 buckets, KMS keys).
#   Both must allow an action for it to succeed (neither alone is sufficient
#   when cross-service invocation is involved).
# ─────────────────────────────────────────────────────────────────────────────
# Grant API Gateway permission to invoke the Lambda function.
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS CLOUDFRONT — Global CDN + HTTPS Termination
#
# CloudFront sits in front of API Gateway for two reasons:
#   1. Global edge network: CloudFront has 400+ edge locations. API Gateway exists
#      only in one region. Routing requests through CloudFront reduces latency for
#      users outside that region (e.g. a Tokyo user calling a us-east-1 API).
#   2. Custom domain + TLS: CloudFront lets you attach an ACM certificate and a
#      custom domain name (e.g. api.myapp.com) without modifying API Gateway.
#      API Gateway's default endpoint is not user-friendly.
#
# Why CloudFront doesn't cache API responses here:
#   min_ttl = default_ttl = max_ttl = 0 — every request passes through to
#   the Lambda function. CloudFront is used for routing and TLS only, not caching.
#   (For static asset caching, see the S3 + CloudFront pattern in the EKS template.)
#
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
    # geo_restriction: block access from specific countries (whitelist or blacklist).
    # restriction_type = "none" means no geographic blocking — all countries can access.
    # To block specific countries: restriction_type = "blacklist", locations = ["CN","RU"]
    # To allow only specific countries: restriction_type = "whitelist", locations = ["US","GB"]
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    # cloudfront_default_certificate uses the *.cloudfront.net domain with HTTPS for free.
    # Replace with acm_certificate_arn for a custom domain (must be in us-east-1).
    # See the EKS CloudFront viewer_certificate block for the full ACM setup explanation.
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
