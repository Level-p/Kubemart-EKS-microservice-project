# ---------------------------------------------------------------------------
# Bootstrap stack (applied once by create-remote-state.sh)
#
# Replaces the Jenkins server: nothing to run or patch, only
#   1. GitHub OIDC identity provider + IAM role -> GitHub Actions gets
#      short-lived AWS credentials, no access keys stored in GitHub
#   2. Wildcard ACM certificate validated through Route 53 (used by every ALB)
# ---------------------------------------------------------------------------

locals {
  name = "kubemart"
}

data "aws_caller_identity" "current" {}

# ---- GitHub OIDC provider (one per AWS account) ----
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

locals {
  github_oidc_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

# ---- Role assumed by the GitHub Actions workflows ----
resource "aws_iam_role" "github_actions" {
  name = "${local.name}-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Only workflows from YOUR repository can assume this role.
        # Classic subject:   repo:OWNER/REPO:...
        # Immutable subject: repo:OWNER@ownerId/REPO@repoId:... (newer repositories)
        StringLike = {
          "token.actions.githubusercontent.com:sub" = compact([
            "repo:${var.github_repository}:*",
            var.github_subject_prefix == "" ? "" : "${var.github_subject_prefix}:*",
          ])
        }
      }
    }]
  })

  max_session_duration = 7200
}

# Terraform creates VPCs, IAM roles, EKS, etc. so it needs broad rights.
# For production, replace with a scoped policy.
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---- Wildcard ACM certificate (*.domain) ----
resource "aws_acm_certificate" "wildcard" {
  domain_name               = var.domain
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name}-acm-cert"
  }
}

data "aws_route53_zone" "zone" {
  name         = var.domain
  private_zone = false
}

resource "aws_route53_record" "acm_validation_record" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = data.aws_route53_zone.zone.zone_id
  allow_overwrite = true
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation_record : record.fqdn]
}
