# Deploy to:   stacks/full-infra/aws-native/automation/terraform/
# Apply:       committed as-is — no sensitive values
# Module:      stacks/full-infra/aws-native
# Requires:    none
#
# Input variable declarations for the aws-native full-stack.
# Parameters modified from baseline: none

# ── PROVIDER ──────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "Primary AWS region for all eu-west-1 resources."
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS CLI named profile used for all provider authentication."
  type        = string
  default     = "multi-lab-admin"
}

# ── SHARED ────────────────────────────────────────────────────────────────────

variable "vpc_name" {
  description = "Name tag of the VPC provisioned by the hardening module. Used by dns, file-transfer, and directory modules for data source lookup."
  type        = string
  default     = "multi-lab-vpc"
}

variable "account_id" {
  description = "12-digit AWS account ID. Used to construct deterministic S3 bucket names in file-transfer and web-server modules."
  type        = string

  validation {
    condition     = can(regex("^\\d{12}$", var.account_id))
    error_message = "The account_id must be a precise 12-digit numeric string."
  }
}

variable "operator_ip" {
  description = "Operator public IP in CIDR notation (e.g. 1.2.3.4/32). Restricts SFTP access on port 22 in the file-transfer module."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.operator_ip))
    error_message = "The operator_ip must be a valid CIDR notation (e.g. 203.0.113.5/32)."
  }
}

# ── HARDENING ─────────────────────────────────────────────────────────────────

variable "cloudtrail_bucket_name" {
  description = "Name of the pre-existing S3 bucket receiving CloudTrail logs."
  type        = string
}

# ── DNS ───────────────────────────────────────────────────────────────────────

# Activate only if you need associate a ec2 instance to your DNS

# variable "ec2_private_ip" {
#   description = "Private IPv4 address of the multi-lab-aws EC2 instance. Value for the A record in the Private Hosted Zone."
#   type        = string
# }

variable "zone_name" {
  description = "Domain name of the Route 53 Private Hosted Zone."
  type        = string
  default     = "multi-lab.internal"
}

variable "a_record_ttl" {
  description = "TTL in seconds for the A record in the Private Hosted Zone."
  type        = number
  default     = 300
}

variable "dns_log_group_name" {
  description = "CloudWatch Logs group name for Route 53 Resolver Query Logging."
  type        = string
  default     = "/aws/route53/multi-lab-vpc"
}

variable "dns_log_retention_days" {
  description = "Retention period in days for the Resolver Query Logs CloudWatch log group."
  type        = number
  default     = 30
}

variable "dns_query_log_config_name" {
  description = "Name of the Route 53 Resolver Query Log configuration."
  type        = string
  default     = "multi-lab-resolver-logging"
}

# ── FILE-TRANSFER ─────────────────────────────────────────────────────────────

variable "eip_allocation_id" {
  description = "Elastic IP allocation ID for the Transfer Family VPC endpoint. Persistent across destroy/redeploy cycles."
  type        = string

  validation {
    condition     = can(regex("^eipalloc-[a-f0-9]+$", var.eip_allocation_id))
    error_message = "The eip_allocation_id must begin with 'eipalloc-' followed by a valid hexadecimal string."
  }
}

variable "sftp_public_key" {
  description = "SSH public key body for the sftpuser Transfer Family logical user."
  type        = string
}

# ── WEB-SERVER ────────────────────────────────────────────────────────────────

variable "domain_name" {
  description = "Primary domain name for the CloudFront distribution, ACM certificate, and Route 53 public records."
  type        = string
  default     = "buildyourinfra.click"
}

variable "hosted_zone_id" {
  description = "Route 53 Public Hosted Zone ID for the apex domain."
  type        = string
}

# ── DIRECTORY (uncomment when enabling module in Step 6) ─────────────────────

variable "ad_admin_password" {
  description = "Admin password for the Managed AD directory. Write-only — never committed."
  type        = string
  sensitive   = true
}

variable "sns_email" {
  description = "Email address for directory alert SNS subscription. Leave empty to skip."
  type        = string
  default     = ""
}