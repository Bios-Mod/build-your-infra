# Deploy to:   modules/hardening/aws-native/automation/terraform/
# Apply:       referenced by import.tf and main.tf
# Module:      modules/hardening/aws-native
# Requires:    terraform.tfvars
#
# Input variable declarations for the hardening aws-native module.
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

# Comentado hasta que se crea 
# ya que no se puede dar un id de un recurso que no existe 

# variable "vpc_id" {
#   description = "ID of multi-lab-vpc — used for default SG lookup and Flow Logs"
#   type        = string
# }

variable "cloudtrail_bucket_name" {
  description = "Name of the S3 bucket receiving CloudTrail logs"
  type        = string
  default     = "multi-lab-cloudtrail"
}