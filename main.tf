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
  default = "ap-northeast-1"
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

module "database" {
  source = "./modules/dynamodb"
  name   = local.name
}

module "function" {
  source       = "./modules/lambda"
  name         = local.name
  table_name   = module.database.table_name
  table_arn    = module.database.table_arn
  source_file  = "${path.root}/lambda/app.py"
  archive_path = "${path.root}/lambda.zip"
}

module "identity" {
  source = "./modules/cognito"
  name   = local.name
}

module "api" {
  source        = "./modules/http_api"
  name          = local.name
  region        = var.region
  user_pool_id  = module.identity.user_pool_id
  client_id     = module.identity.client_id
  function_name = module.function.function_name
  invoke_arn    = module.function.invoke_arn
}

module "monitoring" {
  source        = "./modules/monitoring"
  name          = local.name
  function_name = module.function.function_name
  api_id        = module.api.api_id
}

output "api_url" {
  value = module.api.api_url
}

output "user_pool_id" {
  value = module.identity.user_pool_id
}

output "client_id" {
  value = module.identity.client_id
}
