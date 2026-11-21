############################################################
# 最小構成のセキュアなサーバーレスAPI
############################################################

terraform {
  required_version = ">= 1.5"

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
}

variable "region" {
  type    = string
  default = "ap-northeast-1" # 東京
}

variable "project" {
  type    = string
  default = "mini-serverless"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

locals {
  name = var.project
}

############################################################
# 1. DynamoDB（データ保存）
############################################################
resource "aws_dynamodb_table" "items" {
  name         = "${local.name}-items"
  billing_mode = "PAY_PER_REQUEST" # 使った分だけ課金
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  # 保存時の暗号化（AWS管理のKMSキーを使用）
  server_side_encryption {
    enabled = true
  }

  # 誤削除・誤更新に備えたバックアップ
  point_in_time_recovery {
    enabled = true
  }
}

############################################################
# 2. Lambda
############################################################

# lambda/app.py を zip に固める
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/app.py"
  output_path = "${path.module}/lambda.zip"
}

# ログ保存先（14日で自動削除）
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}-handler"
  retention_in_days = 14
}

# --- IAMロール（最小権限）---
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_permissions" {
  # このテーブルへの書き込み・読み取りだけ許可
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.items.arn]
  }

  # 自分のログ出力だけ許可
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "least-privilege"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

resource "aws_lambda_function" "handler" {
  function_name    = "${local.name}-handler"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "app.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.items.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

############################################################
# 3. Cognito（認証）
############################################################
resource "aws_cognito_user_pool" "main" {
  name = "${local.name}-users"

  # セルフ登録を禁止（管理者だけがユーザーを作成できる）
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }
}

resource "aws_cognito_user_pool_client" "main" {
  name         = "${local.name}-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false # CLI/アプリから使うためシークレットなし

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH", # 動作確認用（本番ではSRP等を推奨）
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"
}

############################################################
# 4. API Gateway（HTTP API）
############################################################
resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"
}

# JWTトークンの検証（Cognitoが発行したトークンのみ通す）
resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  name             = "cognito-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.main.id]
    issuer   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.handler.invoke_arn
  payload_format_version = "2.0"
}

# ルート定義（どちらも認証必須）
resource "aws_apigatewayv2_route" "post_item" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "POST /items"
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "get_item" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /items/{id}"
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "delete_item" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "DELETE /items/{id}"
  target             = "integrations/${aws_apigatewayv2_integration.lambda.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

# API Gatewayのアクセスログ
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${local.name}-api"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  # 過剰アクセス対策（スロットリング）
  default_route_settings {
    throttling_rate_limit  = 5
    throttling_burst_limit = 10
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId = "$context.requestId"
      ip        = "$context.identity.sourceIp"
      time      = "$context.requestTime"
      route     = "$context.routeKey"
      status    = "$context.status"
      error     = "$context.error.message"
    })
  }
}

# API GatewayからLambdaを呼ぶ許可
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

############################################################
# 5. CloudWatch Alarms（監視）
############################################################

# Lambdaでエラーが出たら警告
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.handler.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  # 通知が必要な場合は alarm_actions = [SNSトピックARN] を追加
}

# APIが5xxを返したら警告
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name}-api-5xx"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.main.id }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

############################################################
# 出力（apply後に表示される）
############################################################
output "api_url" {
  value = aws_apigatewayv2_api.main.api_endpoint
}

output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "client_id" {
  value = aws_cognito_user_pool_client.main.id
}
