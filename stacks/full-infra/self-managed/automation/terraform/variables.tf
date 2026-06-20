# Deploy to:   stacks/full-infra/self-managed/terraform/
# Apply:       referenced by import.tf and main.tf
# Module:      stacks/full-infra/self-managed
# Requires:    terraform.tfvars
#
# Input variable declarations for the self-managed stack.
# Parameters modified from baseline: none

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use for authentication"
  type        = string
  default     = "multi-lab-admin"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "ami_id" {
  description = "AMI ID to launch — use the active-directory snapshot by default"
  type        = string
}

variable "key_name" {
  description = "Existing EC2 key pair name"
  type        = string
}