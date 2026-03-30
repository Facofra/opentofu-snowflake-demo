
# A very simple configuration that doesn't need external providers
resource "null_resource" "example2" {
  provisioner "local-exec" {
    command = "echo 'Hello OpenTofu! Environment:. The secret value is: nothing3'"
  }
}



