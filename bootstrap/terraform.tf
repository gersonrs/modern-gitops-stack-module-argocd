terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    utils = {
      source  = "cloudposse/utils"
      version = "~> 2.7"
    }
    htpasswd = {
      source  = "loafoe/htpasswd"
      version = "~> 2.3"
    }
    jwt = {
      source  = "camptocamp/jwt"
      version = "~> 1.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
    argocd = {
      source  = "argoproj-labs/argocd"
      version = "~> 7.18"
    }
  }
  required_version = ">= 1.9.0"
}
