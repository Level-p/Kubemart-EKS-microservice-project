# depends_on makes everything that uses the cluster name (Helm and Kubernetes
# resources) wait until the admin access entries exist.
output "cluster_name" {
  value = aws_eks_cluster.this.name
  depends_on = [
    aws_eks_access_policy_association.admins,
    aws_eks_addon.coredns,
    aws_eks_addon.ebs_csi,
  ]
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "cluster_security_group_id" {
  description = "Security group EKS created for the control plane and nodes"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}
