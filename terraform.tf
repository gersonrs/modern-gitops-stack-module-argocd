terraform {
  required_providers {
    argocd = {
      source  = "argoproj-labs/argocd"
      version = "~> 7.18"
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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.3"
    }
  }
  required_version = ">= 1.9.0"
}
