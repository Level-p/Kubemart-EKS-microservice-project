# ---------------------------------------------------------------------------
# Zalando postgres-operator: runs highly available PostgreSQL clusters.
#
# The app's Helm chart only describes the cluster it wants (a "postgresql"
# object: 3 instances, version 17, 20 GiB). The operator turns that into a
# StatefulSet of Spilo pods (PostgreSQL + Patroni). Patroni keeps one primary
# and streaming replicas, and promotes a replica automatically if the primary
# fails. Kubernetes itself is the "consensus store" (no etcd needed).
# ---------------------------------------------------------------------------

resource "helm_release" "postgres_operator" {
  name             = "postgres-operator"
  repository       = "https://opensource.zalando.com/postgres-operator/charts/postgres-operator"
  chart            = "postgres-operator"
  version          = var.chart_version
  namespace        = "postgres-operator"
  create_namespace = true
  timeout          = 600

  values = [yamlencode({
    configGeneral = {
      # Spilo = PostgreSQL + Patroni + tools, maintained by Zalando
      docker_image = var.spilo_image
    }
    configKubernetes = {
      # Never put two members of one database cluster in the same Availability Zone
      enable_pod_antiaffinity                      = true
      pod_antiaffinity_topology_key                = "topology.kubernetes.io/zone"
      pod_antiaffinity_preferred_during_scheduling = false
      # Data protection: deleting a cluster object must NOT delete its disks or
      # passwords. They are removed on purpose by the destroy workflow instead.
      enable_persistent_volume_claim_deletion = false
      enable_secrets_deletion                 = false
      # Only send traffic to members that Patroni reports as healthy
      enable_readiness_probe = true
      # Run PostgreSQL as the non-root "postgres" user (uid 101) in the Spilo image
      spilo_runasuser  = 101
      spilo_runasgroup = 103
      spilo_fsgroup    = 103
      # Grow disks by editing the PVC (gp3 allows online expansion)
      storage_resize_mode = "pvc"
      watched_namespace   = "*"
    }
  })]
}
