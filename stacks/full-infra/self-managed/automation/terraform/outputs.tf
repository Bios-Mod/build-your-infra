# Deploy to:   stacks/full-infra/self-managed/terraform/
# Apply:       cp outputs.tf.example outputs.tf — activate after import cycle is complete
# Module:      stacks/full-infra/self-managed
# Requires:    main.tf

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_eip.main.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.main.id
}