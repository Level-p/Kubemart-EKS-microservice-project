# ---------------------------------------------------------------------------
# Argo CD (GitOps) and the KubeMart Applications
#   helm_release.argocd       -> Argo CD itself, UI at https://argocd.<domain>
#   kubernetes_secret_v1.repo -> optional credentials for a private Git repo
#   helm_release.argocd_apps  -> AppProject + kubemart-stage / kubemart-prod
# ---------------------------------------------------------------------------

locals {
  argocd_host = "argocd.${var.domain_name}"
  app_path    = "app/helm/ecommerce"

  # Settings shared by both environments
  app_common = {
    namespace  = "argocd"
    project    = "kubemart"
    finalizers = ["resources-finalizer.argocd.argoproj.io"]
    ignoreDifferences = [{
      group        = "apps"
      kind         = "Deployment"
      jsonPointers = ["/spec/replicas"] # replicas are owned by the HPA
    }]
  }

  applications = {
    # Stage: deploys automatically on every Git change and reverts drift
    "kubemart-stage" = merge(local.app_common, {
      source = {
        repoURL        = var.git_repo_url
        targetRevision = var.git_revision
        path           = local.app_path
        helm = {
          releaseName = "kubemart"
          valueFiles  = ["values.yaml", "values-stage.yaml"]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "kubemart-stage"
      }
      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=true"]
        retry = {
          limit   = 5
          backoff = { duration = "10s", factor = 2, maxDuration = "3m" }
        }
      }
    })

    # Prod: Argo CD shows OutOfSync and waits for a person to press Sync
    "kubemart-prod" = merge(local.app_common, {
      source = {
        repoURL        = var.git_repo_url
        targetRevision = var.git_revision
        path           = local.app_path
        helm = {
          releaseName = "kubemart"
          valueFiles  = ["values.yaml", "values-prod.yaml"]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "kubemart-prod"
      }
      syncPolicy = {
        syncOptions = ["CreateNamespace=true"]
      }
    })
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600

  values = [yamlencode({
    global = {
      domain = local.argocd_host
    }
    configs = {
      params = {
        # TLS ends at the ALB, so argocd-server speaks plain HTTP behind it
        "server.insecure" = true
      }
    }
    # Sync status, sync failures and Git fetch errors in Prometheus/Grafana
    controller = {
      metrics = { enabled = true, serviceMonitor = { enabled = var.enable_service_monitors } }
    }
    repoServer = {
      metrics = { enabled = true, serviceMonitor = { enabled = var.enable_service_monitors } }
    }
    server = {
      metrics = { enabled = true, serviceMonitor = { enabled = var.enable_service_monitors } }
      ingress = {
        enabled          = true
        controller       = "generic"
        ingressClassName = "alb"
        hostname         = local.argocd_host
        path             = "/"
        pathType         = "Prefix"
        annotations = {
          "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
          "alb.ingress.kubernetes.io/target-type"      = "ip"
          "alb.ingress.kubernetes.io/group.name"       = var.alb_group_name
          "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTP\": 80}, {\"HTTPS\": 443}]"
          "alb.ingress.kubernetes.io/ssl-redirect"     = "443"
          "alb.ingress.kubernetes.io/certificate-arn"  = var.certificate_arn
          "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"
        }
      }
    }
  })]
}

# Only needed when the Git repository is private
resource "kubernetes_secret_v1" "repo" {
  count = var.git_repo_token == "" ? 0 : 1

  metadata {
    name      = "kubemart-repo"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = var.git_repo_url
    username = var.git_repo_username
    password = var.git_repo_token
  }

  depends_on = [helm_release.argocd]
}

resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = "argocd"

  values = [yamlencode({
    projects = {
      kubemart = {
        namespace   = "argocd"
        description = "KubeMart e-commerce microservices"
        sourceRepos = [var.git_repo_url]
        destinations = [
          { server = "https://kubernetes.default.svc", namespace = "kubemart-stage" },
          { server = "https://kubernetes.default.svc", namespace = "kubemart-prod" },
        ]
        clusterResourceWhitelist   = []
        namespaceResourceWhitelist = [{ group = "*", kind = "*" }]
      }
    }
    applications = local.applications
  })]

  depends_on = [helm_release.argocd, kubernetes_secret_v1.repo]
}
