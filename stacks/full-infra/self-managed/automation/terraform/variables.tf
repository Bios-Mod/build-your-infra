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
  description = "AMI ID to launch (Ubuntu Server 24.04 LTS ARM64 in eu-west-1)"
  type        = string
}

variable "key_name" {
  description = "Existing EC2 key pair name"
  type        = string
}

variable "ssh_bootstrap_cidr" {
  description = "CIDR allowed for temporary SSH bootstrap access on port 22 (e.g. 'X.X.X.X/32'); empty = closed"
  type        = string
  default     = ""
}

variable "ssh_hardened_cidr" {
  description = "CIDR allowed for hardened SSH access on port 22222 before WireGuard lockdown (e.g. 'X.X.X.X/32'); empty = closed"
  type        = string
  default     = ""
}