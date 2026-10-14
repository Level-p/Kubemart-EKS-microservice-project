locals {
  name                 = "kubemart"
  cluster_name         = "kubemart-eks"
  tools_alb_group_name = "platform-tools"               # one ALB shared by Argo CD and Grafana
  loki_url             = "http://loki.logging.svc:3100" # Grafana's Loki data source (module logging)
}

# ---- Lookups (created by the bootstrap stack) ----
data "aws_route53_zone" "zone" {
  name         = var.domain_name
  private_zone = false
}

data "aws_acm_certificate" "cert" {
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

# GitHub Actions runs this Terraform, so its role must be an EKS administrator
data "aws_iam_role" "github_actions" {
  name = "${local.name}-github-actions"
}

# ---- Network ----
module "vpc" {
  source       = "./module/vpc"
  name         = local.name
  cluster_name = local.cluster_name
}

# ---- EKS cluster ----
module "eks" {
  source             = "./module/eks"
  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version
  instance_types     = var.node_instance_types
  node_desired_size  = 3
  node_max_size      = 6
  private_subnet_ids = [
    module.vpc.private_subnet_ids["pri1"],
    module.vpc.private_subnet_ids["pri2"],
    module.vpc.private_subnet_ids["pri3"]
  ]
  admin_principal_arns = distinct(concat([data.aws_iam_role.github_actions.arn], var.admin_principal_arns))
}

# ---- Container registry: one repository per microservice ----
module "ecr" {
  source = "./module/ecr"
  repositories = [
    "${local.name}/frontend",
    "${local.name}/product-catalog",
    "${local.name}/cart",
    "${local.name}/orders",
    "${local.name}/payment",
  ]
}

# ---- Load balancer controller, DNS, metrics, storage ----
module "eks_addons" {
  source         = "./module/eks-addons"
  cluster_name   = module.eks.cluster_name
  region         = var.region
  vpc_id         = module.vpc.vpc_id
  domain_name    = var.domain_name
  hosted_zone_id = data.aws_route53_zone.zone.zone_id
}

# ---- Stage and prod: namespaces, secrets, database backups ----
module "app_namespaces" {
  source       = "./module/app-namespaces"
  name         = local.name
  cluster_name = module.eks.cluster_name
  environments = var.environments

  depends_on = [module.eks_addons]
}

# ---- Metrics: Prometheus, Alertmanager, Grafana ----
module "monitoring" {
  source             = "./module/monitoring"
  domain_name        = var.domain_name
  certificate_arn    = data.aws_acm_certificate.cert.arn
  alb_group_name     = local.tools_alb_group_name
  storage_class_name = module.eks_addons.storage_class_name
  expose_prometheus  = var.expose_prometheus
  loki_url           = local.loki_url

  alert_slack_webhook_url = var.alert_slack_webhook_url

  # The ALB controller webhook must be running before any Ingress is created,
  # and on destroy the Ingresses (ALBs) are removed before the controller.
  depends_on = [module.eks_addons]
}

# ---- PostgreSQL operator: self-managed, highly available databases ----
module "postgres_operator" {
  source = "./module/postgres-operator"

  # needs the gp3 StorageClass and running nodes
  depends_on = [module.eks_addons]
}

# ---- Centralised logging: Loki (logs in S3) + Grafana Alloy, viewed in Grafana ----
module "logging" {
  source             = "./module/logging"
  name               = local.name
  cluster_name       = module.eks.cluster_name
  storage_class_name = module.eks_addons.storage_class_name
  retention_days     = var.log_retention_days

  # The ServiceMonitors of Loki and Alloy need the Prometheus Operator CRDs
  depends_on = [module.eks_addons, module.monitoring]
}

# ---- GitOps: Argo CD and the KubeMart applications ----
module "argocd" {
  source          = "./module/argocd"
  domain_name     = var.domain_name
  certificate_arn = data.aws_acm_certificate.cert.arn
  alb_group_name  = local.tools_alb_group_name
  git_repo_url    = var.git_repo_url
  git_revision    = var.git_revision
  git_repo_token  = var.git_repo_token

  # Before Argo CD deploys KubeMart, the cluster must understand everything in
  # the chart: postgresql (operator), ServiceMonitor/PrometheusRule (monitoring),
  # and the namespaces must hold their secrets and backup settings.
  depends_on = [module.eks_addons, module.app_namespaces, module.monitoring, module.postgres_operator]
}
