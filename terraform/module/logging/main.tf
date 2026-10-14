# ---------------------------------------------------------------------------
# Centralised logging with Loki (viewed in Grafana, next to the metrics):
#   S3 bucket          -> where Loki keeps the logs (cheap; nothing to size)
#   IAM role           -> lets the Loki pod use that bucket (EKS Pod Identity, no keys)
#   Loki               -> one pod (single binary), indexes only labels, compactor
#                         deletes logs older than var.retention
#   Alloy (DaemonSet)  -> on every node: reads every container's log files and
#                         sends them to Loki, labelled namespace/pod/container/level
#   Alloy (events)     -> one pod: stores Kubernetes events (OOMKilled, BackOff,
#                         FailedScheduling...) in Loki
# Grafana gets Loki as a data source in module "monitoring".
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  namespace       = "logging"
  loki_sa         = "loki"
  bucket          = "${var.name}-loki-${data.aws_caller_identity.current.account_id}"
  loki_push_url   = "http://loki.${local.namespace}.svc:3100/loki/api/v1/push"
  retention_hours = "${var.retention_days * 24}h"

  # The Alloy chart passes its config through Helm's template engine (tpl), which
  # would try to run the {{ }} that belong to Alloy (stage.template). Escape them
  # so Helm prints them unchanged: {{ -> {{`{{`}}, }} -> {{`}}`}}
  # (via placeholders, so the second replace does not touch the first one's output)
  alloy_configs = { for f in ["pod-logs", "events"] : f => replace(replace(replace(replace(
    file("${path.module}/config/${f}.alloy"),
    "{{", "@@OPEN@@"), "}}", "@@CLOSE@@"), "@@OPEN@@", "{{`{{`}}"), "@@CLOSE@@", "{{`}}`}}")
  }
}

resource "kubernetes_namespace_v1" "logging" {
  metadata {
    name = local.namespace
  }
}

# ---- 1. Log storage: S3 ----
resource "aws_s3_bucket" "loki" {
  bucket        = local.bucket
  force_destroy = true # logs are disposable; terraform destroy empties the bucket
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "loki_tls" {
  bucket = aws_s3_bucket.loki.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.loki.arn, "${aws_s3_bucket.loki.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.loki]
}

# Safety net: Loki's compactor deletes old logs itself; anything it misses goes after twice the retention
resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    id     = "expire-leftovers"
    status = "Enabled"
    filter {}
    expiration {
      days = var.retention_days * 2
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ---- 2. Loki's AWS access (EKS Pod Identity) ----
resource "aws_iam_role" "loki" {
  name = "${var.name}-loki"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "loki" {
  name = "loki-bucket"
  role = aws_iam_role.loki.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.loki.arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.loki.arn}/*" },
    ]
  })
}

resource "aws_eks_pod_identity_association" "loki" {
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = local.loki_sa
  role_arn        = aws_iam_role.loki.arn
}

# ---- 3. Loki ----
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name
  timeout    = 600

  values = [yamlencode({
    deploymentMode = "SingleBinary"
    loki = {
      auth_enabled = false # one tenant: the whole cluster
      commonConfig = { replication_factor = 1 }
      schemaConfig = {
        configs = [{
          from         = "2026-01-01"
          store        = "tsdb"
          object_store = "s3"
          schema       = "v13"
          index        = { prefix = "loki_index_", period = "24h" }
        }]
      }
      storage = {
        type        = "s3"
        bucketNames = { chunks = aws_s3_bucket.loki.bucket, ruler = aws_s3_bucket.loki.bucket, admin = aws_s3_bucket.loki.bucket }
        s3          = { region = data.aws_region.current.region }
      }
      limits_config = {
        retention_period           = local.retention_hours
        reject_old_samples         = true
        reject_old_samples_max_age = "168h"
        max_query_lookback         = local.retention_hours
        volume_enabled             = true
      }
      compactor = {
        retention_enabled    = true
        delete_request_store = "s3"
      }
    }
    serviceAccount = { create = true, name = local.loki_sa }
    singleBinary = {
      replicas = 1
      persistence = {
        enabled      = true
        storageClass = var.storage_class_name
        size         = "10Gi" # write-ahead log and index cache; the logs themselves are in S3
      }
      resources = {
        requests = { cpu = "100m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
    }
    # Simple-scalable components and caches off: one pod is plenty for a startup
    backend      = { replicas = 0 }
    read         = { replicas = 0 }
    write        = { replicas = 0 }
    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    gateway      = { enabled = false }
    lokiCanary   = { enabled = false }
    test         = { enabled = false }
    minio        = { enabled = false }
    # Prometheus watches Loki itself (ingestion, errors)
    monitoring = { serviceMonitor = { enabled = true } }
  })]

  depends_on = [aws_eks_pod_identity_association.loki, aws_iam_role_policy.loki]
}

# ---- 4. Log collection: Alloy on every node ----
resource "helm_release" "alloy_logs" {
  name       = "alloy-logs"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.alloy_chart_version
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name

  values = [yamlencode({
    controller = {
      type        = "daemonset"
      tolerations = [{ operator = "Exists" }] # every node
    }
    alloy = {
      configMap = { content = local.alloy_configs["pod-logs"] }
      mounts    = { varlog = true } # /var/log/pods on the node
      extraEnv  = [{ name = "LOKI_PUSH_URL", value = local.loki_push_url }]
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "384Mi" }
      }
    }
    serviceMonitor = { enabled = true }
  })]

  depends_on = [helm_release.loki]
}

# ---- 5. Kubernetes events: one Alloy ----
resource "helm_release" "alloy_events" {
  name       = "alloy-events"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.alloy_chart_version
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name

  values = [yamlencode({
    controller = { type = "deployment", replicas = 1 }
    alloy = {
      configMap = { content = local.alloy_configs["events"] }
      extraEnv  = [{ name = "LOKI_PUSH_URL", value = local.loki_push_url }]
      resources = {
        requests = { cpu = "10m", memory = "64Mi" }
        limits   = { memory = "256Mi" }
      }
    }
    serviceMonitor = { enabled = true }
  })]

  depends_on = [helm_release.loki]
}
