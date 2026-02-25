terraform {
  required_version = ">= 1.6.0"

  required_providers {
    twc = {
      source = "tf.timeweb.cloud/timeweb-cloud/timeweb-cloud"
    }
  }
}

provider "twc" {
  token = var.twc_token != "" ? var.twc_token : null
}
