# A very simple configuration that doesn't need external providers
resource "null_resource" "example" {
  provisioner "local-exec" {
    command = "echo 'Hello from OpenTofu! Environment: ${var.environment}. The secret value is: ${nonsensitive(var.my_github_secret)}'"
  }
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "my_github_secret" {
  type      = string
  sensitive = true # This hides the value from OpenTofu logs
}