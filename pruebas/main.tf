terraform {
  required_version = ">= 1.6"
  required_providers {
    null    = { source = "hashicorp/null",    version = "~> 3.2" }
  }
}

resource "null_resource" "echo_public_keys2" {

  provisioner "local-exec" {
    command = "echo 'nada que se yo'"
  }
}
