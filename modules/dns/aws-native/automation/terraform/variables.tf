# Deploy to:   modules/dns/aws-native/automation/terraform/variables.tf
# Apply:       committed — no sensitive values
# Module:      dns / aws-native / automation
# Requires:    none
#
# Input variable declarations for the DNS aws-native Terraform module.
# Parameters modified from baseline:  none

variable "aws_region" {
  description = "AWS region for all resources in this module."
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "AWS CLI named profile used for authentication."
  type        = string
  default     = "multi-lab-admin"
}

variable "vpc_name" {
  description = "Name tag of the VPC to associate with the Private Hosted Zone. Used by the data source lookup."
  type        = string
  default     = "multi-lab-vpc"
}

variable "zone_name" {
  description = "Domain name of the Route 53 Private Hosted Zone."
  type        = string
  default     = "multi-lab.internal"
}

variable "ec2_private_ip" {
  description = "Private IPv4 address of the multi-lab-aws EC2 instance. Used as the value for the A record."
  type        = string
}

variable "a_record_ttl" {
  description = "TTL in seconds for the A records in the Private Hosted Zone."
  type        = number
  default     = 300
}

variable "log_group_name" {
  description = "CloudWatch Logs group name for Route 53 Resolver Query Logging."
  type        = string
  default     = "/aws/route53/multi-lab-vpc"
}

variable "log_retention_days" {
  description = "Retention period in days for the Resolver Query Logs CloudWatch log group."
  type        = number
  default     = 30
}

variable "query_log_config_name" {
  description = "Name of the Route 53 Resolver Query Log configuration."
  type        = string
  default     = "multi-lab-resolver-logging"
}