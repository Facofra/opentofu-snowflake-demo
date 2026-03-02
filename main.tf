# A very simple configuration that doesn't need external providers
resource "null_resource" "example" {
  provisioner "local-exec" {
    command = "echo 'Hello from OpenTofu! Environment: ${var.environment}'"
  }
}

variable "environment" {
  type    = string
  default = "dev"
}