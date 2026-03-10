terraform {
  backend "s3" {
    # configure these values for your environment
    bucket = "opentofu-state-demo-bucket"
    key    = "terraform.tfstate"
    region = "us-east-1"
    use_lockfile=true
  }
}


# A very simple configuration that doesn't need external providers
resource "null_resource" "example2" {
  provisioner "local-exec" {
    command = "echo 'Hello OpenTofu! Environment: ${var.environment}. The secret value is: ${nonsensitive(var.my_github_secret)}'"
  }
}



variable "environment" {
  type    = string
  default = "dev"
}

variable "my_github_secret" {
  type      = string
  sensitive = true # This hides the value from OpenTofu logs
  default = "secret_value"

}