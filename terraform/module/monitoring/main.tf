# ---------------------------------------------------------------------------
# Metrics: kube-prometheus-stack = Prometheus Operator, Prometheus, Alertmanager,
# Grafana, node-exporter and kube-state-metrics in one Helm release.
# Prometheus and Grafana keep their data on gp3 EBS volumes (StatefulSets).
#
# Logs are in Loki (module logging), added to Grafana as a data source, so one
# screen answers: is something wrong, where, since when (metrics) and why (logs).
# Alertmanager posts alerts to Slack when var.alert_slack_webhook_url is set.
# ---------------------------------------------------------------------------

locals {
  grafana_host    = "grafana.${var.domain_name}"
  prometheus_host = "prometheus.${var.domain_name}"

  # Same ALB as Argo CD (IngressGroup "platform-tools")

  # Only "is a webhook set?" is revealed, never the URL itself
  slack_enabled = nonsensitive(var.alert_slack_webhook_url != "")

  # Alertmanager: every alert to Slack (when a webhook is set), grouped per alert and
  # namespace, repeated every 4 hours while it fires, and once more when it resolves.
  # The webhook URL is read from a mounted Secret, so it never appears in the config.
  alertmanager_config = {
    global = { resolve_timeout = "5m" }
    route = {
      receiver        = local.slack_enabled ? "slack" : "null"
      group_by        = ["alertname", "namespace"]
      group_wait      = "30s"
      group_interval  = "5m"
      repeat_interval = "4h"
      routes = [
        # Always-firing helpers of kube-prometheus-stack, and informational alerts
        { receiver = "null", matchers = ["alertname =~ \"Watchdog|InfoInhibitor\""] },
        { receiver = "null", matchers = ["severity = \"info\""] },
      ]
    }
    inhibit_rules = [
      # A critical alert hides the warning with the same name and namespace
      { source_matchers = ["severity = \"critical\""], target_matchers = ["severity = \"warning\""], equal = ["alertname", "namespace"] },
    ]
    receivers = concat([{ name = "null" }], local.slack_enabled ? [{
      name = "slack"
      slack_configs = [{
        api_url_file  = "/etc/alertmanager/secrets/alertmanager-slack/webhook-url"
        send_resolved = true
        color         = "{{ if eq .Status \"firing\" }}{{ if eq .CommonLabels.severity \"critical\" }}danger{{ else }}warning{{ end }}{{ else }}good{{ end }}"
        title         = "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}{{ if .CommonLabels.namespace }} ({{ .CommonLabels.namespace }}){{ end }}"
        title_link    = "https://${local.grafana_host}/d/kubemart-overview"
        text          = "{{ range .Alerts }}*{{ .Labels.severity }}*: {{ if .Annotations.summary }}{{ .Annotations.summary }}{{ else }}{{ .Annotations.description }}{{ end }}\n{{ end }}"
      }]
    }] : [])
  }
  alb_annotations = {
    "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
    "alb.ingress.kubernetes.io/target-type"     = "ip"
    "alb.ingress.kubernetes.io/group.name"      = var.alb_group_name
    "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\": 80}, {\"HTTPS\": 443}]"
    "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
    "alb.ingress.kubernetes.io/certificate-arn" = var.certificate_arn
    "alb.ingress.kubernetes.io/success-codes"   = "200-399"
  }

  values = {
    crds = { enabled = true }

    # EKS runs the control plane for us: these components cannot be scraped,
    # so disable them to avoid permanent "target down" alerts.
    kubeEtcd              = { enabled = false }
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeProxy             = { enabled = false }

    grafana = {
      defaultDashboardsTimezone = "browser"
      ingress = {
        enabled          = true
        ingressClassName = "alb"
        annotations = merge(local.alb_annotations, {
          "alb.ingress.kubernetes.io/healthcheck-path" = "/api/health"
        })
        hosts = [local.grafana_host]
        path  = "/"
        tls   = [{ hosts = [local.grafana_host] }]
      }
      # Grafana as a StatefulSet with its own EBS volume
      persistence = {
        enabled          = true
        type             = "sts"
        storageClassName = var.storage_class_name
        accessModes      = ["ReadWriteOnce"]
        size             = "10Gi"
      }
      # Logs next to the metrics: Explore > Loki, and the log panels of KubeMart overview
      additionalDataSources = [{
        name      = "Loki"
        uid       = "loki"
        type      = "loki"
        access    = "proxy"
        url       = var.loki_url
        isDefault = false
        jsonData  = { maxLines = 1000 }
      }]
      sidecar = {
        dashboards = {
          enabled         = true
          label           = "grafana_dashboard"
          labelValue      = "1"
          searchNamespace = "ALL" # picks up the KubeMart dashboard ConfigMap (kubemart-prod)
        }
      }
    }

    prometheus = {
      ingress = {
        enabled          = var.expose_prometheus
        ingressClassName = "alb"
        annotations = merge(local.alb_annotations, {
          "alb.ingress.kubernetes.io/healthcheck-path" = "/-/healthy"
        })
        hosts    = [local.prometheus_host]
        paths    = ["/"]
        pathType = "Prefix"
        tls      = [{ hosts = [local.prometheus_host] }]
      }
      prometheusSpec = {
        retention = var.prometheus_retention
        # Discover ServiceMonitors / PrometheusRules from ALL Helm releases,
        # not only from this one (needed for the KubeMart chart, Argo CD, Loki and Alloy)
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = var.storage_class_name
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = var.prometheus_storage_size } }
            }
          }
        }
        resources = {
          requests = { cpu = "250m", memory = "1Gi" }
          limits   = { memory = "2Gi" }
        }
      }
    }

    alertmanager = {
      config = local.alertmanager_config
      alertmanagerSpec = {
        # Mounted at /etc/alertmanager/secrets/alertmanager-slack/ (created below)
        secrets = local.slack_enabled ? ["alertmanager-slack"] : []
        storage = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = var.storage_class_name
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = "2Gi" } }
            }
          }
        }
      }
    }
  }
}

# Generated once and kept in the Terraform state; read it with the command in
# the output "grafana_admin_password_command"
resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.chart_version
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 900

  values = [yamlencode(local.values)]

  # Kept out of the values file so it never appears in plan output
  set_sensitive = [{
    name  = "grafana.adminPassword"
    value = random_password.grafana_admin.result
  }]
}

# Slack incoming webhook for Alertmanager (the pod waits for it to exist)
resource "kubernetes_secret_v1" "alertmanager_slack" {
  count = local.slack_enabled ? 1 : 0

  metadata {
    name      = "alertmanager-slack"
    namespace = helm_release.kube_prometheus_stack.namespace
  }

  data = {
    "webhook-url" = var.alert_slack_webhook_url
  }
}
