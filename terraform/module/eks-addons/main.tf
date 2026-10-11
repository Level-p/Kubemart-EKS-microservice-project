# ---------------------------------------------------------------------------
# Cluster add-ons installed with Helm:
#   - AWS Load Balancer Controller (Ingress -> Application Load Balancer)
#   - ExternalDNS (Ingress host -> Route 53 record)
#   - metrics-server (kubectl top, Horizontal Pod Autoscaler)
#   - gp3 StorageClass used by every StatefulSet volume
# AWS permissions are granted with EKS Pod Identity (no static keys).
# ---------------------------------------------------------------------------

locals {
  # Trust policy shared by every Pod Identity role
  pod_identity_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# ---- Default StorageClass: encrypted gp3, expandable ----
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = var.storage_reclaim_policy
  volume_binding_mode    = "WaitForFirstConsumer" # create the volume in the AZ where the pod lands
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }
}

# ---- AWS Load Balancer Controller ----
resource "aws_iam_policy" "lbc" {
  name        = "${var.cluster_name}-aws-load-balancer-controller"
  description = "Official AWS Load Balancer Controller policy (v3.5.0)"
  policy      = file("${path.module}/policies/aws-load-balancer-controller.json")
}

resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lbc_chart_version
  namespace  = "kube-system"
  wait       = true

  values = [yamlencode({
    clusterName  = var.cluster_name
    region       = var.region
    vpcId        = var.vpc_id
    replicaCount = 2
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
  })]

  depends_on = [
    aws_eks_pod_identity_association.lbc,
    aws_iam_role_policy_attachment.lbc,
  ]
}

# ---- ExternalDNS ----
resource "aws_iam_role" "external_dns" {
  name               = "${var.cluster_name}-external-dns"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy" "external_dns" {
  name = "route53-records"
  role = aws_iam_role.external_dns.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource",
          "route53:ListTagsForResources",
        ]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "external_dns" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns.arn
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = var.external_dns_chart_version
  namespace  = "kube-system"

  values = [yamlencode({
    provider      = { name = "aws" }
    policy        = "sync" # also removes records when an Ingress is deleted
    registry      = "txt"
    txtOwnerId    = var.cluster_name
    domainFilters = [var.domain_name]
    sources       = ["ingress", "service"]
    extraArgs     = ["--aws-zone-type=public"]
    env = [{
      name  = "AWS_DEFAULT_REGION"
      value = var.region
    }]
    serviceAccount = {
      create = true
      name   = "external-dns"
    }
  })]

  depends_on = [aws_eks_pod_identity_association.external_dns]
}

# ---- metrics-server ----
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"
}
