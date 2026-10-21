terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  https_canary_name    = "portal-https"
  tcp_metric_namespace = "UptimeMonitoring"
  tcp_metric_name      = "TcpPortOpen"
  check_period_seconds = 300
}

data "aws_caller_identity" "current" {}

# -------------------------------------------------------------------
# Alerts
# -------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "uptime-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "sms" {
  for_each = toset(var.alert_sms_numbers)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "sms"
  endpoint  = each.value
}

# -------------------------------------------------------------------
# Monitor 1: HTTPS canary
# -------------------------------------------------------------------

resource "aws_s3_bucket" "canary_artifacts" {
  bucket_prefix = "uptime-canary-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "canary_artifacts" {
  bucket = aws_s3_bucket.canary_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "canary_artifacts" {
  bucket = aws_s3_bucket.canary_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "canary_artifacts" {
  bucket = aws_s3_bucket.canary_artifacts.id

  rule {
    id     = "expire-canary-artifacts"
    status = "Enabled"

    filter {}

    expiration {
      days = 31
    }
  }
}

data "archive_file" "canary" {
  type        = "zip"
  source_file = "${path.module}/canary/heartbeat.js"
  output_path = "${path.module}/build/canary.zip"
}

resource "terraform_data" "canary_script" {
  input = data.archive_file.canary.output_base64sha256
}

resource "aws_iam_role" "canary" {
  name = "uptime-https-canary"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "canary" {
  name = "uptime-https-canary"
  role = aws_iam_role.canary.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.canary_artifacts.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation"]
        Resource = aws_s3_bucket.canary_artifacts.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:CreateLogGroup",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/cwsyn-${local.https_canary_name}*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListAllMyBuckets", "xray:PutTraceSegments"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "CloudWatchSynthetics"
          }
        }
      },
    ]
  })
}

resource "aws_synthetics_canary" "https" {
  name                 = local.https_canary_name
  artifact_s3_location = "s3://${aws_s3_bucket.canary_artifacts.bucket}/portal-https"
  execution_role_arn   = aws_iam_role.canary.arn
  runtime_version      = "syn-nodejs-5.3"
  handler              = "heartbeat.handler"
  zip_file             = data.archive_file.canary.output_path
  start_canary         = true

  schedule {
    expression = "rate(5 minutes)"
  }

  run_config {
    timeout_in_seconds = 60
    memory_in_mb       = 960
    environment_variables = {
      TARGET_URL  = var.http_url
      SCRIPT_HASH = data.archive_file.canary.output_base64sha256
    }
  }

  success_retention_period = 7
  failure_retention_period = 31

  lifecycle {
    replace_triggered_by = [terraform_data.canary_script]
  }

  depends_on = [
    aws_iam_role_policy.canary,
    aws_s3_bucket_public_access_block.canary_artifacts,
  ]
}

resource "aws_cloudwatch_metric_alarm" "https" {
  alarm_name          = "uptime-https-portal"
  alarm_description   = "The registration portal failed ${var.consecutive_failures} HTTPS checks in a row."
  namespace           = "CloudWatchSynthetics"
  metric_name         = "SuccessPercent"
  statistic           = "Average"
  period              = local.check_period_seconds
  evaluation_periods  = var.consecutive_failures
  datapoints_to_alarm = var.consecutive_failures
  threshold           = 100
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    CanaryName = aws_synthetics_canary.https.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = var.notify_on_recovery ? [aws_sns_topic.alerts.arn] : []
}

# -------------------------------------------------------------------
# Monitor 2: TCP port check
# -------------------------------------------------------------------

data "archive_file" "tcp_check" {
  type        = "zip"
  source_file = "${path.module}/lambda/tcp_check.py"
  output_path = "${path.module}/build/tcp_check.zip"
}

resource "aws_cloudwatch_log_group" "tcp_check" {
  name              = "/aws/lambda/uptime-tcp-check"
  retention_in_days = 14
}

resource "aws_iam_role" "tcp_check" {
  name = "uptime-tcp-check"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "tcp_check" {
  name = "uptime-tcp-check"
  role = aws_iam_role.tcp_check.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.tcp_check.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = local.tcp_metric_namespace
          }
        }
      },
    ]
  })
}

resource "aws_lambda_function" "tcp_check" {
  function_name                  = "uptime-tcp-check"
  role                           = aws_iam_role.tcp_check.arn
  runtime                        = "python3.12"
  handler                        = "tcp_check.handler"
  filename                       = data.archive_file.tcp_check.output_path
  source_code_hash               = data.archive_file.tcp_check.output_base64sha256
  timeout     = 15
  memory_size = 128

  environment {
    variables = {
      TARGET_HOST      = var.tcp_host
      TARGET_PORT      = tostring(var.tcp_port)
      TIMEOUT_SECONDS  = "5"
      METRIC_NAMESPACE = local.tcp_metric_namespace
      METRIC_NAME      = local.tcp_metric_name
    }
  }

  depends_on = [
    aws_iam_role_policy.tcp_check,
    aws_cloudwatch_log_group.tcp_check,
  ]
}

resource "aws_cloudwatch_event_rule" "tcp_check" {
  name                = "uptime-tcp-check"
  description         = "Run the TCP port check every 5 minutes."
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "tcp_check" {
  rule = aws_cloudwatch_event_rule.tcp_check.name
  arn  = aws_lambda_function.tcp_check.arn
}

resource "aws_lambda_permission" "tcp_check" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tcp_check.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.tcp_check.arn
}

resource "aws_cloudwatch_metric_alarm" "tcp" {
  alarm_name          = "uptime-tcp-port"
  alarm_description   = "Port ${var.tcp_port} on ${var.tcp_host} failed ${var.consecutive_failures} checks in a row."
  namespace           = local.tcp_metric_namespace
  metric_name         = local.tcp_metric_name
  statistic           = "Minimum"
  period              = local.check_period_seconds
  evaluation_periods  = var.consecutive_failures
  datapoints_to_alarm = var.consecutive_failures
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    Host = var.tcp_host
    Port = tostring(var.tcp_port)
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = var.notify_on_recovery ? [aws_sns_topic.alerts.arn] : []
}
