
locals {
  argocd_version  = yamldecode(file("${path.module}/chart-version.yaml")).appVersion
  argocd_hostname = "argocd.${var.subdomain != "" ? "${trimprefix(var.subdomain, ".")}." : ""}${var.base_domain}"

  jwt_tokens = {
    for account in var.extra_accounts : account => {
      jti = random_uuid.jti[account].result
      iat = time_static.iat[account].unix
      iss = "argocd"
      nbf = time_static.iat[account].unix
      sub = account
    }
  }

  extra_accounts_tokens = { for account in var.extra_accounts : format("accounts.%s.tokens", account) => replace(jsonencode([
    {
      id  = random_uuid.jti[account].result
      iat = time_static.iat[account].unix
    }
  ]), "\\\"", "\"") }

  extra_objects = [
    {
      apiVersion = "v1"
      kind       = "ConfigMap"
      metadata = {
        name = "kustomized-helm-cm"
      }
      data = {
        "plugin.yaml" = <<-EOT
          apiVersion: argoproj.io/v1alpha1
          kind: ConfigManagementPlugin
          metadata:
            name: kustomized-helm
          spec:
            init:
              command: ["/bin/sh", "-c"]
              args: ["helm dependency build || true"]
            generate:
              command: ["/bin/sh", "-c"]
              args: ["echo \"$ARGOCD_ENV_HELM_VALUES\" | helm template . --name-template $ARGOCD_APP_NAME --namespace $ARGOCD_APP_NAMESPACE $ARGOCD_ENV_HELM_ARGS -f - --include-crds > all.yaml && kustomize build"]
        EOT
      }
    }
  ]

  repo_server_extra_containers = [
    {
      name    = "kustomized-helm-cmp"
      command = ["/var/run/argocd/argocd-cmp-server"]
      # Note: Argo CD official image ships Helm and Kustomize. No need to build a custom image to use "kustomized-helm" plugin.
      image = "quay.io/argoproj/argocd:${local.argocd_version}"
      args  = ["--loglevel=warn"]
      securityContext = {
        runAsNonRoot = true
        runAsUser    = 999
      }
      volumeMounts = [
        {
          mountPath = "/var/run/argocd"
          name      = "var-files"
        },
        {
          mountPath = "/home/argocd/cmp-server/plugins"
          name      = "plugins"
        },
        {
          mountPath = "/home/argocd/cmp-server/config/plugin.yaml"
          subPath   = "plugin.yaml"
          name      = "kustomized-helm-cm"
        },
        {
          mountPath = "/tmp"
          name      = "kustomized-helm-cmp-tmp"
        }
      ]
      # The extra containers of the repo_server pod must have resource requests/limits in order to allow this component
      # to autoscale properly.
      resources = {
        requests = { for k, v in var.resources.kustomized_helm_cmp.requests : k => v if v != null }
        limits   = { for k, v in var.resources.kustomized_helm_cmp.limits : k => v if v != null }
      }
    }
  ]

  repo_server_volumes = [
    {
      configMap = {
        name = "kustomized-helm-cm"
      }
      name = "kustomized-helm-cm"
    },
    {
      name     = "helmfile-cmp-tmp"
      emptyDir = {}
    },
    {
      name     = "kustomized-helm-cmp-tmp"
      emptyDir = {}
    }
  ]

  helm_values = [{
    argo-cd = {
      global = {
        networkPolicy = {
          create = false
        }
        domain = local.argocd_hostname
      }
      configs = merge(length(var.repositories) > 0 ? {
        repositories = var.repositories
        } : null, {
        cm = merge({ for account in var.extra_accounts : format("accounts.%s", account) => "apiKey" }, {
          "url"                           = "https://${local.argocd_hostname}"
          "accounts.pipeline"             = "apiKey"
          "admin.enabled"                 = var.admin_enabled
          "exec.enabled"                  = var.exec_enabled
          "oidc.config"                   = <<-EOT
            ${yamlencode(merge(var.oidc, { clientSecret = "$oidc.default.clientSecret" }))}
          EOT
          "oidc.tls.insecure.skip.verify" = var.cluster_issuer != "letsencrypt-prod"
          "resource.customizations"       = <<-EOT
            argoproj.io/Application: # https://argo-cd.readthedocs.io/en/stable/operator-manual/health/#argocd-app
              health.lua: |
                hs = {}
                hs.status = "Progressing"
                hs.message = ""
                if obj.status ~= nil then
                  if obj.status.health ~= nil then
                    hs.status = obj.status.health.status
                    if obj.status.health.message ~= nil then
                      hs.message = obj.status.health.message
                    end
                  end
                end
                return hs
            networking.k8s.io/Ingress: # https://argo-cd.readthedocs.io/en/stable/faq/#why-is-my-application-stuck-in-progressing-state
              health.lua: |
                hs = {}
                hs.status = "Healthy"
                return hs
          EOT
        })
        params = {
          "server.insecure" = true # We terminate the SSL connection at the Istio Gateway
        }
        rbac = {
          scopes           = var.rbac.scopes
          "policy.default" = var.rbac.policy_default
          "policy.csv"     = var.rbac.policy_csv
        }
        secret = {
          extra = merge({
            "accounts.pipeline.tokens"  = "${replace(var.accounts_pipeline_tokens, "\\\"", "\"")}"
            "server.secretkey"          = "${replace(var.server_secretkey, "\\\"", "\"")}"
            "oidc.default.clientSecret" = "${replace(var.oidc.clientSecret, "\\\"", "\"")}"
          }, local.extra_accounts_tokens)
        }
        }, var.ssh_known_hosts != null ? {
        ssh = {
          knownHosts = var.ssh_known_hosts
        }
      } : null)
      applicationSet = {
        replicas = var.high_availability.enabled ? var.high_availability.application_set.replicas : null
        resources = {
          requests = { for k, v in var.resources.application_set.requests : k => v if v != null }
          limits   = { for k, v in var.resources.application_set.limits : k => v if v != null }
        }
      }
      controller = {
        replicas = var.high_availability.enabled ? var.high_availability.controller.replicas : null
        resources = {
          requests = { for k, v in var.resources.controller.requests : k => v if v != null }
          limits   = { for k, v in var.resources.controller.limits : k => v if v != null }
        }
        metrics = {
          enabled = var.enable_service_monitor
          serviceMonitor = {
            enabled = var.enable_service_monitor
          }
        }
      }
      dex = {
        enabled = false
      }
      repoServer = {
        replicas = var.high_availability.enabled && !var.high_availability.repo_server.autoscaling.enabled ? var.high_availability.repo_server.replicas : null
        autoscaling = {
          enabled     = var.high_availability.repo_server.autoscaling.enabled
          minReplicas = var.high_availability.repo_server.autoscaling.min_replicas
          maxReplicas = var.high_availability.repo_server.autoscaling.max_replicas
        }
        resources = {
          requests = { for k, v in var.resources.repo_server.requests : k => v if v != null }
          limits   = { for k, v in var.resources.repo_server.limits : k => v if v != null }
        }
        metrics = {
          enabled = var.enable_service_monitor
          serviceMonitor = {
            enabled = var.enable_service_monitor
          }
        }
        volumes         = local.repo_server_volumes
        extraContainers = local.repo_server_extra_containers


      }
      extraObjects = local.extra_objects
      server = {
        replicas = var.high_availability.enabled && !var.high_availability.server.autoscaling.enabled ? var.high_availability.server.replicas : null
        autoscaling = {
          enabled     = var.high_availability.server.autoscaling.enabled
          minReplicas = var.high_availability.server.autoscaling.min_replicas
          maxReplicas = var.high_availability.server.autoscaling.max_replicas
        }
        resources = {
          requests = { for k, v in var.resources.server.requests : k => v if v != null }
          limits   = { for k, v in var.resources.server.limits : k => v if v != null }
        }
        ingress = {
          enabled = false
        }
        metrics = {
          enabled = var.enable_service_monitor
          serviceMonitor = {
            enabled = var.enable_service_monitor
          }
        }
      }
      notifications = {
        resources = {
          requests = { for k, v in var.resources.notifications.requests : k => v if v != null }
          limits   = { for k, v in var.resources.notifications.limits : k => v if v != null }
        }
      }
      # When the Redis HA is enabled, the default Redis chart is not used, so we change the value to null.
      redis = !var.high_availability.enabled ? {
        resources = {
          requests = { for k, v in var.resources.redis.requests : k => v if v != null }
          limits   = { for k, v in var.resources.redis.limits : k => v if v != null }
        }
      } : null
      redis-ha = {
        enabled = var.high_availability.enabled
      }
    }
  }]

  helm_values_httproute = [{
    httproute = {
      enabled           = true
      host              = local.argocd_hostname
      gateway_name      = var.gateway_name
      gateway_namespace = var.gateway_namespace
    }
  }]
}
