# Deploy to:   modules/file-transfer/aws-native/automation/terraform/
# Apply:       committed — no sensitive values
# Module:      file-transfer / aws-native
# Requires:    none
#
# Input variable declarations for the file-transfer aws-native Terraform module.
# Parameters modified from baseline: none

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

variable "account_id" {
  description = "12-digit AWS account ID. Used to construct the S3 bucket name."
  type        = string

  validation {
    condition     = can(regex("^\\d{12}$", var.account_id))
    error_message = "The account_id must be a precise 12-digit numeric string."
  }
}

variable "operator_ip" {
  description = "Operator public IP in CIDR notation (e.g. 1.2.3.4/32). Restricts SFTP access on port 22."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.operator_ip))
    error_message = "The operator_ip must be a valid CIDR notation (e.g., 192.0.2.0/24 or 203.0.113.5/32)."
  }
}

variable "vpc_id" {
  description = "VPC ID for multi-lab-vpc. Used to scope the Security Group."
  type        = string

  validation {
    condition     = can(regex("^vpc-[a-f0-9]+$", var.vpc_id))
    error_message = "The vpc_id must begin with 'vpc-' followed by a valid hexadecimal string."
  }
}

variable "subnet_id" {
  description = "Public subnet ID (10.0.1.0/24) for the Transfer Family VPC endpoint."
  type        = string

  validation {
    condition     = can(regex("^subnet-[a-f0-9]+$", var.subnet_id))
    error_message = "The subnet_id must begin with 'subnet-' followed by a valid hexadecimal string."
  }
}

variable "eip_allocation_id" {
  description = "Elastic IP allocation ID to associate with the Transfer Family server endpoint."
  type        = string

  validation {
    condition     = can(regex("^eipalloc-[a-f0-9]+$", var.eip_allocation_id))
    error_message = "The eip_allocation_id must begin with 'eipalloc-' followed by a valid hexadecimal string."
  }
}

variable "sftp_public_key" {
  description = "SSH public key body for the sftpuser logical user. Paste the full public key string."
  type        = string
  # Removed sensitive = true. Public keys are non-sensitive by design and essential for state verification.
}