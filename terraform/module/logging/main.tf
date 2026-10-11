# ---------------------------------------------------------------------------
# Centralised logging (EFK):
#   ECK operator      -> manages Elasticsearch and Kibana on Kubernetes
#   elastic-stack     -> local chart: Elasticsearch (StatefulSet + EBS) + Kibana + Ingress
#   Fluent Bit        -> DaemonSet that tails every container log on every node
#                        and ships it to Elasticsearch
# ---------------------------------------------------------------------------

locals {
  namespace   = "logging"
  es_name     = "logging"
  kibana_host = "kibana.${var.domain_name}"

  # Fluent Bit output. $${...} escapes Terraform interpolation, so Fluent Bit
  # receives the literal ${ES_PASSWORD} and reads it from the environment.
  fluent_bit_outputs = <<-EOT
    [OUTPUT]
        Name               es
        Match              kube.*
        Host               ${local.es_name}-es-http.${local.namespace}.svc
        Port               9200
        HTTP_User          elastic
        HTTP_Passwd        $${ES_PASSWORD}
        tls                On
        tls.verify         Off
        Logstash_Format    On
        Logstash_Prefix    kubernetes
        Time_Key           ingest_timestamp
        Suppress_Type_Name On
        Replace_Dots       On
        Trace_Error        On
        Retry_Limit        5
  EOT

  # Only container logs (the chart default also reads systemd journals)
  fluent_bit_inputs = <<-EOT
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Exclude_Path      /var/log/containers/fluent-bit*
        multiline.parser  docker, cri
        Tag               kube.*
        Mem_Buf_Limit     10MB
        Skip_Long_Lines   On
  EOT
}

# ---- ECK operator ----
resource "helm_release" "eck_operator" {
  name             = "elastic-operator"
  repository       = "https://helm.elastic.co"
  chart            = "eck-operator"
  version          = var.eck_operator_chart_version
  namespace        = "elastic-system"
  create_namespace = true
  wait             = true
}

# ---- Elasticsearch + Kibana (CRDs from the operator above) ----
resource "helm_release" "elastic_stack" {
  name             = "elastic-stack"
  chart            = "${path.module}/charts/elastic-stack"
  namespace        = local.namespace
  create_namespace = true

  values = [yamlencode({
    name    = local.es_name
    version = var.elastic_version
    elasticsearch = {
      nodeCount    = var.elasticsearch_node_count
      storageClass = var.storage_class_name
      storageSize  = var.elasticsearch_storage_size
      memory       = "2Gi"
      cpu          = "500m"
    }
    kibana = {
      host   = local.kibana_host
      memory = "1Gi"
      cpu    = "250m"
    }
    ingress = {
      className      = "alb"
      groupName      = var.alb_group_name
      certificateArn = var.certificate_arn
    }
  })]

  depends_on = [helm_release.eck_operator]
}

# ---- Fluent Bit log shipper ----
resource "helm_release" "fluent_bit" {
  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = var.fluent_bit_chart_version
  namespace  = local.namespace

  values = [yamlencode({
    # Password Secret created by ECK for the "elastic" user
    env = [{
      name = "ES_PASSWORD"
      valueFrom = {
        secretKeyRef = {
          name = "${local.es_name}-es-elastic-user"
          key  = "elastic"
        }
      }
    }]
    config = {
      inputs  = local.fluent_bit_inputs
      outputs = local.fluent_bit_outputs
    }
    # Prometheus scrapes Fluent Bit, so "logs are not reaching Elasticsearch"
    # shows up in Grafana (fluentbit_output_errors_total)
    serviceMonitor = {
      enabled = var.enable_service_monitor
    }
  })]

  depends_on = [helm_release.elastic_stack]
}
