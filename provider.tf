terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 5.10"
    }
    kubernetes = {
      version = "= 2.22.0"
    }
    local = {
      version = "= 2.4.0"
    }
    helm = {
      version = "= 2.10.1"
    }
  }
}

provider "tls" {}

provider "local" {}

provider "kubernetes" {
    host                   = data.aws_eks_cluster.default.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.default.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
      command     = "aws"
    }
  }

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.default.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.default.certificate_authority[0].data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
      command     = "aws"
    }
  }
}

provider "aws" {
  # No credentials explicitly set here because they come from either the
  # environment or the global credentials file.
  default_tags {
    tags = {
      Name = var.cluster_name
    }
  }
  region = var.region
}
