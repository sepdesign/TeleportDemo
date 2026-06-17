output "control_plane_public_ip" {
  description = "Elastic IP of the control plane. Use for SSH and the kubeconfig."
  value       = aws_eip.cp.public_ip
}

output "control_plane_private_ip" {
  description = "Private IP of the control plane. Used by kubeadm init."
  value       = aws_instance.cp.private_ip
}

output "ingress_public_ip" {
  description = "Elastic IP of worker 1. Point the DNS A record here."
  value       = aws_eip.ingress.public_ip
}

output "worker_private_ips" {
  description = "Private IPs of the workers"
  value       = [for w in aws_instance.worker : w.private_ip]
}

output "worker_public_ips" {
  description = "Public IPs of the workers. Worker 2 changes on stop and start."
  value       = [for w in aws_instance.worker : w.public_ip]
}

output "ssh_control_plane" {
  description = "SSH command for the control plane"
  value       = "ssh -i ${var.project}-key.pem ubuntu@${aws_eip.cp.public_ip}"
}

output "ssh_ingress_worker" {
  description = "SSH command for worker 1"
  value       = "ssh -i ${var.project}-key.pem ubuntu@${aws_eip.ingress.public_ip}"
}
