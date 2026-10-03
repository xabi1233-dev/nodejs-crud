# Outputs.
#
# `terraform output` reads from state, so these cost nothing and never hit the
# AWS API.

output "instance_public_ip" {
  description = "Public IP of the production instance"
  value       = aws_instance.crud.public_ip
}

output "instance_id" {
  description = "ID of the production instance, for aws ec2 commands"
  value       = aws_instance.crud.id
}

# --- Scratch box ------------------------------------------------------------
# try() keeps these from erroring when scratch_enabled is false and the
# resource has count = 0.

output "scratch_public_ip" {
  description = "Public IP of the throwaway test instance"
  value       = try(aws_instance.scratch[0].public_ip, "not running")
}

output "scratch_ssh" {
  description = "Command to connect to the scratch box"
  value = try(
    "ssh -i ~/.ssh/crud-key.pem ubuntu@${aws_instance.scratch[0].public_ip}",
    "scratch instance not running — terraform apply -var=\"scratch_enabled=true\""
  )
}

output "scratch_watch_boot" {
  description = "Watch cloud-init run the user_data script live"
  value = try(
    "ssh -i ~/.ssh/crud-key.pem ubuntu@${aws_instance.scratch[0].public_ip} 'sudo tail -f /var/log/cloud-init-output.log'",
    "scratch instance not running"
  )
}

output "scratch_test_url" {
  description = "Hit this once user_data reports finished"
  value       = try("http://${aws_instance.scratch[0].public_ip}/health", "scratch instance not running")
}
