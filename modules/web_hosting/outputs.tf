output "bucket_name" {
  value = aws_s3_bucket.site.id
}

output "frontend_url" {
  value = "https://${aws_cloudfront_distribution.site.domain_name}"
}
