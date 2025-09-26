output "public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.web.public_ip
}

output "http_url" {
  description = "Convenience URL"
  value       = "http://${aws_instance.web.public_ip}/"
}
