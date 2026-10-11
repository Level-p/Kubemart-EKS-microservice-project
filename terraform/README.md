# KubeMart on Amazon EKS: Terraform

Infrastructure as code for the KubeMart e-commerce project: **EKS, ECR, Argo CD (GitOps), Prometheus and Grafana (metrics), Elasticsearch, Kibana and Fluent Bit (logs), and the PostgreSQL operator** that runs the shop's highly available databases inside the cluster, plus the AWS Load Balancer Controller and ExternalDNS. **GitHub Actions** runs it (no CI server to host).

![DevOps architecture](../architecture/kubemart-devops-architecture.png)

Diagrams: [`../architecture/`](../architecture/). Step-by-step guide: **`../docs/KubeMart-EKS-Deployment-Guide.docx`**. The workflows are in [`../.github/workflows`](../.github/workflows) (this folder's parent is the repository root).

## Layout (same structure as the sock-shop project)

```text
create-remote-state.sh     creates the S3 state bucket, then applies bootstrap/ (run once, from your laptop)
destroy-remote-state.sh    destroys bootstrap/ and deletes the bucket (run last, from your laptop)
main.tf / provider.tf / variable.tf / output.tf
bootstrap/                 GitHub OIDC provider + role for GitHub Actions, wildcard ACM certificate
module/vpc                 VPC, subnets, NAT, ELB subnet tags
module/eks                 EKS cluster, node group, add-ons (VPC CNI prefix delegation), access entries
module/ecr                 5 ECR repositories (kubemart/*)
module/eks-addons          Load Balancer Controller, ExternalDNS, metrics-server, gp3 StorageClass
module/app-namespaces      kubemart-stage / kubemart-prod: Pod Security labels, frontend and Valkey
                           secrets, S3 backup bucket, backup IAM roles (Pod Identity), db-backup-config
module/postgres-operator   Zalando postgres-operator: runs the 3-member PostgreSQL clusters
module/monitoring          kube-prometheus-stack: Prometheus, Alertmanager, Grafana (generated password)
module/logging             ECK operator, Elasticsearch + Kibana (local chart), Fluent Bit (+ ServiceMonitor)
module/argocd              Argo CD (+ metrics) + AppProject + kubemart-stage / kubemart-prod Applications
```

Order of creation: VPC, EKS, add-ons, then namespaces, monitoring and the postgres-operator, then logging and finally Argo CD. Argo CD comes last because the KubeMart chart uses resource types the other modules install (`postgresql`, `ServiceMonitor`, `PrometheusRule`) and secrets they create.

## Quick start

```bash
# 1. change: state bucket name (create/destroy scripts + both provider.tf), domain,
#    bootstrap/variable.tf github_repository, admin_principal_arns (your IAM ARN)
./create-remote-state.sh      # bucket + bootstrap; prints the role ARN for GitHub
                              # (detects an existing GitHub OIDC provider and the
                              #  immutable subject format by itself)

# 2. GitHub: secret AWS_ROLE_ARN (optional GIT_REPO_TOKEN for a private repo),
#    variable DOMAIN_NAME, environments "infrastructure" and "production" with
#    required reviewers, "stage" with none

# 3. Actions: "KubeMart Infrastructure" (apply), then "KubeMart Application"
#    (Run workflow builds all 5 services), later "KubeMart Promote to Production"
```

## URLs after deployment

| Service | URL |
|---|---|
| Argo CD | `https://argocd.<domain>` (admin password: `terraform output argocd_admin_password_command`) |
| Grafana | `https://grafana.<domain>` (user `admin`: `terraform output grafana_admin_password_command`), dashboard **KubeMart overview** |
| Prometheus | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090` (no login, so not public) |
| Kibana | `https://kibana.<domain>` (user `elastic`: `terraform output kibana_password_command`) |
| Shop | `https://shop-stage.<domain>`, `https://shop.<domain>` |

Database backups: `aws s3 ls s3://$(terraform output -raw db_backup_bucket)/prod/`.

## Sizing

3 × t3.large (2 vCPU, 8 GiB) carry everything: Elasticsearch (2 GiB), Kibana, Prometheus, Grafana, Argo CD, and per environment five services, 3 PostgreSQL members and Valkey. The node group can grow to 6. Do not go below 3 nodes: the 3 database members must run in 3 different Availability Zones.

## Teardown

Run **KubeMart Infrastructure** with `destroy` (it waits for the `infrastructure` approval). It deletes the Argo CD applications, then the PostgreSQL clusters, Valkey and their disks (Argo CD is told never to delete them by itself), so the ALBs and EBS volumes are gone before Terraform removes the cluster. Then run `./destroy-remote-state.sh` from your laptop. The backup bucket is emptied and deleted too (`force_destroy_backups = true`; set it to `false` when the data matters).
