# nexus-infra-lakehouse / terraform / envs / lakehouse-minio / variables.tf

# --- Shared paths -----------------------------------------------------------
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
  default = "C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
}
variable "vnet_primary" {
  type    = string
  default = "VMnet11"
}
variable "vnet_secondary" {
  type    = string
  default = "VMnet10"
}

# ─── Per-VM toggles (4 nodes) ─────────────────────────────────────────────
variable "enable_minio_1" {
  type    = bool
  default = true
}
variable "enable_minio_2" {
  type    = bool
  default = true
}
variable "enable_minio_3" {
  type    = bool
  default = true
}
variable "enable_minio_4" {
  type    = bool
  default = true
}

# Per-VM MACs (block :9A-:9D, the contiguous range after StarRocks :98).
# MUST match nexus-infra-vmware foundation env's mac_lakehouse_minio_*_primary.
variable "mac_minio_1_primary" {
  type    = string
  default = "00:50:56:3F:00:9A"
}
variable "mac_minio_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:9A"
}
variable "mac_minio_2_primary" {
  type    = string
  default = "00:50:56:3F:00:9B"
}
variable "mac_minio_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:9B"
}
variable "mac_minio_3_primary" {
  type    = string
  default = "00:50:56:3F:00:9C"
}
variable "mac_minio_3_secondary" {
  type    = string
  default = "00:50:56:3F:01:9C"
}
variable "mac_minio_4_primary" {
  type    = string
  default = "00:50:56:3F:00:9D"
}
variable "mac_minio_4_secondary" {
  type    = string
  default = "00:50:56:3F:01:9D"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────
variable "enable_minio_nftables_backplane" {
  type    = bool
  default = true
}
variable "enable_minio_vault_agents" {
  type    = bool
  default = true
}
variable "enable_minio_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_minio_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_minio_3_vault_agent" {
  type    = bool
  default = true
}
variable "enable_minio_4_vault_agent" {
  type    = bool
  default = true
}
variable "enable_minio_tls" {
  type    = bool
  default = true
}
variable "enable_minio_config" {
  type        = bool
  default     = true
  description = "role-overlay-minio-config.tf -- render /etc/nexus-minio/minio.conf (MINIO_VOLUMES across 4 backplane IPs + Vault-KV root creds + TLS certs dir) + enable/start all 4 nodes together as one erasure set."
}
variable "enable_minio_bucket_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-minio-bucket-bootstrap.tf -- one-shot exit gate: mc alias + create the warehouse/spark-events buckets + the least-priv lakehouse-app service account + verify erasure-set health + node-loss tolerance."
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
variable "vault_agent_minio_creds_dir" {
  type    = string
  default = "$HOME/.nexus"
}
variable "vault_pki_ca_bundle_path" {
  type    = string
  default = "$HOME/.nexus/vault-ca-bundle.crt"
}
variable "vault_pki_minio_role_name" {
  type    = string
  default = "minio-server"
}

# ─── KV creds (sticky-seeded by the security env) ─────────────────────────
variable "kv_root_user_path" {
  type        = string
  default     = "nexus/lakehouse/minio/root-user"
  description = "Vault KV path holding the MinIO root access key (MINIO_ROOT_USER)."
}
variable "kv_root_password_path" {
  type        = string
  default     = "nexus/lakehouse/minio/root-password"
  description = "Vault KV path holding the MinIO root secret key (MINIO_ROOT_PASSWORD)."
}
variable "kv_app_access_key_path" {
  type        = string
  default     = "nexus/lakehouse/minio/app-access-key"
  description = "Vault KV path holding the least-priv lakehouse-app service account access key (consumed by Spark + Iceberg)."
}
variable "kv_app_secret_key_path" {
  type        = string
  default     = "nexus/lakehouse/minio/app-secret-key"
  description = "Vault KV path holding the least-priv lakehouse-app service account secret key."
}

# ─── MinIO cluster shape ──────────────────────────────────────────────────
variable "minio_warehouse_bucket" {
  type        = string
  default     = "warehouse"
  description = "Primary Iceberg warehouse bucket (s3://warehouse) created by the bucket-bootstrap exit gate."
}
variable "minio_extra_buckets" {
  type        = list(string)
  default     = ["spark-events", "lakehouse"]
  description = "Additional buckets created at bootstrap (spark-events = Spark history logs; lakehouse = medallion bronze/silver/gold root)."
}
