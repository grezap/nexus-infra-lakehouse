/*
 * variables.tf -- envs/lakehouse-spark (Phase 0.L.3)
 *
 * Per-VM enable toggles default true (steady state); opt-out is the explicit
 * override (memory/feedback_terraform_partial_apply_destroys_resources.md).
 */

# ─── Shared paths ─────────────────────────────────────────────────────────
variable "template_root" {
  type    = string
  default = "H:\\VMS\\NexusPlatform\\_templates"
}
variable "vm_output_dir_root" {
  type    = string
  default = "H:\\VMS\\NexusPlatform"
}
variable "vmrun_path" {
  type    = string
  default = "C:/Program Files/VMware/VMware Workstation/vmrun.exe"
}
variable "vnet_primary" {
  type    = string
  default = "VMnet11"
}
variable "vnet_secondary" {
  type    = string
  default = "VMnet10"
}

# ─── Per-VM toggles (8 nodes) ─────────────────────────────────────────────
variable "enable_spark_master_1" {
  type    = bool
  default = true
}
variable "enable_spark_master_2" {
  type    = bool
  default = true
}
variable "enable_spark_worker_1" {
  type    = bool
  default = true
}
variable "enable_spark_worker_2" {
  type    = bool
  default = true
}
variable "enable_spark_worker_3" {
  type    = bool
  default = true
}
variable "enable_zookeeper_1" {
  type    = bool
  default = true
}
variable "enable_zookeeper_2" {
  type    = bool
  default = true
}
variable "enable_zookeeper_3" {
  type    = bool
  default = true
}

# ─── Per-VM MACs ──────────────────────────────────────────────────────────
# Spark masters/workers reuse the original lakehouse block (:99/:9E/:9F) + the
# 0.L.3 expansion (:AA/:AB); ZooKeeper uses :AC-:AE. Secondary NIC = :01: variant.
# MUST match nexus-infra-vmware foundation env's mac_lakehouse_*_primary.
variable "mac_spark_master_1_primary" {
  type    = string
  default = "00:50:56:3F:00:99"
}
variable "mac_spark_master_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:99"
}
variable "mac_spark_master_2_primary" {
  type    = string
  default = "00:50:56:3F:00:AA"
}
variable "mac_spark_master_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:AA"
}
variable "mac_spark_worker_1_primary" {
  type    = string
  default = "00:50:56:3F:00:9E"
}
variable "mac_spark_worker_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:9E"
}
variable "mac_spark_worker_2_primary" {
  type    = string
  default = "00:50:56:3F:00:9F"
}
variable "mac_spark_worker_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:9F"
}
variable "mac_spark_worker_3_primary" {
  type    = string
  default = "00:50:56:3F:00:AB"
}
variable "mac_spark_worker_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:AB"
}
variable "mac_zookeeper_1_primary" {
  type    = string
  default = "00:50:56:3F:00:AC"
}
variable "mac_zookeeper_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:AC"
}
variable "mac_zookeeper_2_primary" {
  type    = string
  default = "00:50:56:3F:00:AD"
}
variable "mac_zookeeper_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:AD"
}
variable "mac_zookeeper_3_primary" {
  type    = string
  default = "00:50:56:3F:00:AE"
}
variable "mac_zookeeper_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:AE"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────
variable "enable_spark_nftables_backplane" {
  type    = bool
  default = true
}
variable "enable_spark_vault_agents" {
  type    = bool
  default = true
}
variable "enable_spark_master_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_spark_master_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_spark_worker_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_spark_worker_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_spark_worker_3_vault_agent" {
  type    = bool
  default = true
}
variable "enable_spark_tls" {
  type    = bool
  default = true
}
variable "enable_zk_ensemble" {
  type    = bool
  default = true
}
variable "enable_spark_config" {
  type    = bool
  default = true
}
variable "enable_spark_cluster_bootstrap" {
  type    = bool
  default = true
}

# ─── Operator + cross-env coupling vars ───────────────────────────────────
variable "lakehouse_node_user" {
  type    = string
  default = "nexusadmin"
}
variable "lakehouse_cluster_timeout_minutes" {
  type    = number
  default = 25
}
variable "vault_agent_version" {
  type    = string
  default = "1.18.5"
}
variable "vault_agent_spark_creds_dir" {
  type    = string
  default = "$HOME/.nexus"
}
variable "vault_pki_ca_bundle_path" {
  type    = string
  default = "$HOME/.nexus/vault-ca-bundle.crt"
}
variable "vault_pki_spark_role_name" {
  type    = string
  default = "spark-server"
}

# ─── KV creds (sticky-seeded by the security env) ─────────────────────────
variable "kv_spark_auth_secret_path" {
  type    = string
  default = "nexus/lakehouse/spark/auth-secret"
}
variable "kv_minio_app_access_key_path" {
  type    = string
  default = "nexus/lakehouse/minio/app-access-key"
}
variable "kv_minio_app_secret_key_path" {
  type    = string
  default = "nexus/lakehouse/minio/app-secret-key"
}

# ─── Topology ─────────────────────────────────────────────────────────────
variable "spark_master_dns_name" {
  type    = string
  default = "spark-master.nexus.lab"
}
# The multi-master cluster URL uses node IPs (robust, no DNS dependency).
variable "spark_master_ips" {
  type    = list(string)
  default = ["192.168.70.140", "192.168.70.153"]
}
# ZooKeeper is reached over the VMnet10 backplane (client port 2181).
variable "zookeeper_backplane_ips" {
  type    = list(string)
  default = ["192.168.10.155", "192.168.10.156", "192.168.10.157"]
}
variable "zookeeper_client_port" {
  type    = number
  default = 2181
}
variable "iceberg_rest_uri" {
  description = "The Iceberg REST catalog (Nessie) endpoint Spark registers as a catalog (0.L.2 round-robin front door)."
  type        = string
  default     = "https://iceberg.nexus.lab:19120/iceberg/"
}
variable "minio_s3_endpoint" {
  type    = string
  default = "https://minio.nexus.lab:9000"
}
variable "iceberg_warehouse_bucket" {
  type    = string
  default = "warehouse"
}
variable "spark_events_bucket" {
  type    = string
  default = "spark-events"
}
