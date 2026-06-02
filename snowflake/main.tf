terraform {
  required_version = ">= 1.6"
  required_providers {
    null    = { source = "hashicorp/null",    version = "~> 3.2" }
  }
}

resource "null_resource" "echo_public_keys" {
  count = 0
  provisioner "local-exec" {
    command = "echo 'nada que se yo'"
  }
}
