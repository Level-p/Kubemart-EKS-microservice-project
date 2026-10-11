# Save this value as the GitHub repository secret AWS_ROLE_ARN
output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "certificate_arn" {
  value = aws_acm_certificate_validation.wildcard.certificate_arn
}
