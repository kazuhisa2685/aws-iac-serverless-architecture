locals {
  app_js = replace(
    replace(
      replace(
        replace(file("${path.root}/frontend/app.js"), "__API_URL__", var.api_url),
        "__REGION__", var.region
      ),
      "__CLIENT_ID__", var.client_id
    ),
    "__COGNITO_DOMAIN__", var.cognito_domain
  )
}

resource "aws_s3_object" "index" {
  bucket        = var.bucket_name
  key           = "index.html"
  source        = "${path.root}/frontend/index.html"
  etag          = filemd5("${path.root}/frontend/index.html")
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache"
}

resource "aws_s3_object" "app" {
  bucket        = var.bucket_name
  key           = "app.js"
  content       = local.app_js
  etag          = md5(local.app_js)
  content_type  = "application/javascript; charset=utf-8"
  cache_control = "no-cache"
}

resource "aws_s3_object" "styles" {
  bucket        = var.bucket_name
  key           = "styles.css"
  source        = "${path.root}/frontend/styles.css"
  etag          = filemd5("${path.root}/frontend/styles.css")
  content_type  = "text/css; charset=utf-8"
  cache_control = "no-cache"
}
