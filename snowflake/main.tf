
# A very simple configuration that doesn't need external providers
resource "null_resource" "example" {
  count = 0
  provisioner "local-exec" {
    command = "echo 'Hello OpenTofu! Environment'"
  }
}
