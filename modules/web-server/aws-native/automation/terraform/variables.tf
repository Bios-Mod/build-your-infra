# Deploy to:   modules/web-server/aws-native/automation/terraform/
# Apply:       committed as-is — no secrets
# Module:      web-server / aws-native
# Requires:    none
#
# Input variable declarations for the web server Terraform module.
# Parameters modified from baseline:  none

variable "aws_region" {
  description = "Primary AWS region for eu-west-1 resources (S3, CloudFront, Route 53)"
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS CLI named profile used for all provider authentication"
  type        = string
  default     = "multi-lab-admin"
}

variable "account_id" {
  description = "AWS account ID — used to construct deterministic resource names"
  type        = string
}

variable "domain_name" {
  description = "Primary domain name for the CloudFront distribution and ACM certificate"
  type        = string
  default     = "buildyourinfra.click"
}

variable "hosted_zone_id" {
  description = "Route 53 Public Hosted Zone ID for buildyourinfra.click"
  type        = string
}

variable "html_dir" {
  description = "Absolute or relative path to the html directory containing index.html. Defaults to the standard location relative to this module."
  type        = string
  default     = "../../../html"
}