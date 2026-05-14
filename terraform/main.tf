###############################################################
#  URL Shortener – Terraform Infrastructure
#  Region : eu-central-1 (Frankfurt)
###############################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # ── Remote state (S3 backend) ──────────────────────────────
  backend "s3" {
    bucket = "url-shortener-tfstate-339712755065"
    key    = "url-shortener/terraform.tfstate"
    region = "eu-central-1"
  }
}

provider "aws" {
  region = var.aws_region
}

###############################################################
#  VARIABLES
###############################################################

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Prefix applied to every resource name"
  type        = string
  default     = "url-shortener"
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 10
}

variable "lambda_memory" {
  description = "Lambda memory in MB"
  type        = number
  default     = 128
}

###############################################################
#  DYNAMODB TABLE
###############################################################

resource "aws_dynamodb_table" "urls" {
  name         = "${var.project_name}-urls"
  billing_mode = "PAY_PER_REQUEST"   # free-tier friendly, scales automatically
  hash_key     = "short_code"

  attribute {
    name = "short_code"
    type = "S"
  }

  tags = {
    Project     = var.project_name
    Environment = "production"
  }
}

###############################################################
#  IAM – Lambda execution role
###############################################################

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.project_name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# ── API Gateway account-level CloudWatch role ──────────────────────────────
# API Gateway requires a CloudWatch Logs role to be set at the account level

data "aws_iam_policy_document" "apigw_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_cloudwatch" {
  name               = "${var.project_name}-apigw-cloudwatch-role"
  assume_role_policy = data.aws_iam_policy_document.apigw_assume_role.json
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  role       = aws_iam_role.apigw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch.arn
}

# CloudWatch Logs – basic Lambda logging
resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Least-privilege DynamoDB access (only the actions the function needs)
data "aws_iam_policy_document" "dynamo_access" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
    ]
    resources = [aws_dynamodb_table.urls.arn]
  }
}

resource "aws_iam_role_policy" "dynamo_access" {
  name   = "${var.project_name}-dynamo-access"
  role   = aws_iam_role.lambda_exec.id
  policy = data.aws_iam_policy_document.dynamo_access.json
}

###############################################################
#  LAMBDA FUNCTION
###############################################################

# Zip the lambda source directory
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/../lambda/handler.zip"
}

resource "aws_lambda_function" "url_shortener" {
  function_name    = var.project_name
  description      = "URL Shortener – creates short codes and redirects"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.urls.name
      BASE_URL   = "https://${aws_api_gateway_rest_api.api.id}.execute-api.${var.aws_region}.amazonaws.com/prod"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_logs,
    aws_iam_role_policy.dynamo_access,
  ]

  tags = {
    Project     = var.project_name
    Environment = "production"
  }
}

###############################################################
#  API GATEWAY
###############################################################

resource "aws_api_gateway_rest_api" "api" {
  name        = "${var.project_name}-api"
  description = "REST API for the URL Shortener"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# ── POST /shorten ──────────────────────────────────────────

resource "aws_api_gateway_resource" "shorten" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "shorten"
}

resource "aws_api_gateway_method" "shorten_post" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.shorten.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "shorten_post" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.shorten.id
  http_method             = aws_api_gateway_method.shorten_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.url_shortener.invoke_arn
}

# CORS preflight for /shorten
resource "aws_api_gateway_method" "shorten_options" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.shorten.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "shorten_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.shorten.id
  http_method = aws_api_gateway_method.shorten_options.http_method
  type        = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "shorten_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.shorten.id
  http_method = aws_api_gateway_method.shorten_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "shorten_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.shorten.id
  http_method = aws_api_gateway_method.shorten_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.shorten_options]
}

# ── GET /{code} ────────────────────────────────────────────

resource "aws_api_gateway_resource" "code" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "{code}"
}

resource "aws_api_gateway_method" "code_get" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.code.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "code_get" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.code.id
  http_method             = aws_api_gateway_method.code_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.url_shortener.invoke_arn
}

# ── Deployment & Stage ─────────────────────────────────────

resource "aws_api_gateway_deployment" "api" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  triggers = {
    # Re-deploy whenever any method or integration changes
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.shorten,
      aws_api_gateway_method.shorten_post,
      aws_api_gateway_integration.shorten_post,
      aws_api_gateway_resource.code,
      aws_api_gateway_method.code_get,
      aws_api_gateway_integration.code_get,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.shorten_post,
    aws_api_gateway_integration.code_get,
  ]
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.api.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "prod"

  depends_on = [aws_api_gateway_account.main]

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.path"
      status         = "$context.status"
      responseLength = "$context.responseLength"
    })
  }

  tags = {
    Project     = var.project_name
    Environment = "production"
  }
}

# ── Lambda permission for API Gateway ──────────────────────

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.url_shortener.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

###############################################################
#  CLOUDWATCH – Logs & Alarms
###############################################################

# Log group for the Lambda function
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}"
  retention_in_days = 14

  tags = {
    Project = var.project_name
  }
}

# Log group for API Gateway access logs
resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/api-gateway/${var.project_name}"
  retention_in_days = 14

  tags = {
    Project = var.project_name
  }
}

# Alarm: Lambda errors > 5 in 5 minutes
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors"
  alarm_description   = "Fires when Lambda throws more than 5 errors in 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.url_shortener.function_name
  }
}

# Alarm: Lambda p99 duration > 3 seconds
resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  alarm_name          = "${var.project_name}-lambda-duration"
  alarm_description   = "Fires when Lambda p99 duration exceeds 3 seconds"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  extended_statistic  = "p99"
  threshold           = 3000
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.url_shortener.function_name
  }
}

###############################################################
#  BILLING ALARM  (protects your free tier)
###############################################################

# Billing alarms must be created in us-east-1 — AWS requirement
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

resource "aws_cloudwatch_metric_alarm" "billing" {
  provider            = aws.us_east_1
  alarm_name          = "${var.project_name}-billing-alert"
  alarm_description   = "Alert when estimated charges exceed $5"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 86400   # checked once per day
  statistic           = "Maximum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    Currency = "USD"
  }
}

###############################################################
#  FRONTEND – S3 Static Website + CloudFront CDN
###############################################################

# S3 bucket to hold the frontend files
resource "aws_s3_bucket" "frontend" {
  bucket        = "${var.project_name}-frontend-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Project     = var.project_name
    Environment = "production"
  }
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Block all public access — CloudFront will be the only entry point
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFront Origin Access Control — lets CloudFront read the bucket privately
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project_name}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# S3 bucket policy — only allow CloudFront to read objects
data "aws_iam_policy_document" "frontend_bucket_policy" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.frontend.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_bucket_policy.json
}

# Upload the HTML file to S3, injecting the real API URL
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  content_type = "text/html"

  # Replace the placeholder with the real API Gateway URL
  content = replace(
    file("${path.module}/../frontend/index.html"),
    "REPLACE_WITH_YOUR_API_URL",
    "https://${aws_api_gateway_rest_api.api.id}.execute-api.${var.aws_region}.amazonaws.com/prod"
  )

  # Invalidate CloudFront cache whenever the HTML changes
  etag = md5(replace(
    file("${path.module}/../frontend/index.html"),
    "REPLACE_WITH_YOUR_API_URL",
    "https://${aws_api_gateway_rest_api.api.id}.execute-api.${var.aws_region}.amazonaws.com/prod"
  ))
}

# CloudFront distribution
resource "aws_cloudfront_distribution" "frontend" {
  provider = aws.us_east_1
  enabled             = true
  default_root_object = "index.html"
  comment             = "${var.project_name} frontend"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 3600
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Project     = var.project_name
    Environment = "production"
  }
}

###############################################################
#  OUTPUTS
###############################################################

output "frontend_url" {
  description = "CloudFront URL of the frontend"
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}

output "api_base_url" {
  description = "Base URL of the deployed API"
  value       = "https://${aws_api_gateway_rest_api.api.id}.execute-api.${var.aws_region}.amazonaws.com/prod"
}

output "shorten_endpoint" {
  description = "Endpoint to create a short URL"
  value       = "https://${aws_api_gateway_rest_api.api.id}.execute-api.${var.aws_region}.amazonaws.com/prod/shorten"
}

output "dynamodb_table_name" {
  description = "Name of the DynamoDB table"
  value       = aws_dynamodb_table.urls.name
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.url_shortener.function_name
}
