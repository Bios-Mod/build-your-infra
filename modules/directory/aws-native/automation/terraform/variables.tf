# Terraform AWS Directory Service — build-your-infra
# Module:   modules/directory/aws-native/automation/terraform

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS CLI profile used by the provider."
  type        = string
  default     = "multi-lab-admin"
}

variable "vpc_name" {
  description = "Name tag of the VPC managed by the hardening module."
  type        = string
  default     = "multi-lab-vpc"
}

variable "ad_admin_password" {
  description = "Admin password for the Managed AD directory. Write-only — never committed."
  type        = string
  sensitive   = true
}

variable "sns_email" {
  description = "Email address for directory alert SNS subscription. Leave empty to skip subscription."
  type        = string
  default     = ""
}