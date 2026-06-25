# nexus-infra-lakehouse / terraform / envs / lakehouse-iceberg / variables.tf

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

# ─── Per-VM toggles (4 nodes) ─────────────────────────────────────────────
variable "enable_iceberg_pg_1" {
  type    = bool
  default = true
}
variable "enable_iceberg_pg_2" {
  type    = bool
  default = true
}
variable "enable_iceberg_rest_1" {
  type    = bool
  default = true
}
variable "enable_iceberg_rest_2" {
  type    = bool
  default = true
}

# Per-VM MACs (block :A0-:A3, after MinIO :9D + Harbor :A4 is registry-side).
# MUST match nexus-infra-vmware foundation env's mac_lakehouse_iceberg_*_primary.
variable "mac_iceberg_rest_1_primary" {
  type    = string
  default = "00:50:56:3F:00:A0"
}
variable "mac_iceberg_rest_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:A0"
}
variable "mac_iceberg_rest_2_primary" {
  type    = string
  default = "00:50:56:3F:00:A1"
}
variable "mac_iceberg_rest_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:A1"
}
variable "mac_iceberg_pg_1_primary" {
  type    = string
  default = "00:50:56:3F:00:A2"
}
variable "mac_iceberg_pg_1_secondary" {
  type    = string
  default = "00:50:56:3F:01:A2"
}
variable "mac_iceberg_pg_2_primary" {
  type    = string
  default = "00:50:56:3F:00:A3"
}
variable "mac_iceberg_pg_2_secondary" {
  type    = string
  default = "00:50:56:3F:01:A3"
}

# ─── Per-overlay toggles ──────────────────────────────────────────────────
variable "enable_iceberg_nftables_backplane" {
  type    = bool
  default = true
}
variable "enable_iceberg_vault_agents" {
  type    = bool
  default = true
}
variable "enable_iceberg_pg_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_iceberg_pg_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_iceberg_rest_1_vault_agent" {
  type    = bool
  default = true
}
variable "enable_iceberg_rest_2_vault_agent" {
  type    = bool
  default = true
}
variable "enable_iceberg_tls" {
  type    = bool
  default = true
}
variable "enable_iceberg_pg_replication" {
  type        = bool
  default     = true
  description = "role-overlay-iceberg-pg-replication.tf -- primary postgresql.conf/pg_hba + roles + nessie DB; replica pg_basebackup + standby; keepalived VRRP VIP .151 with auto-promotion."
}
variable "enable_nessie_config" {
  type        = bool
  default     = true
  description = "role-overlay-nessie-config.tf -- render /etc/nexus-iceberg-rest/nessie.env (JDBC -> iceberg-db VIP; S3 -> MinIO; Quarkus HTTPS) + import the Vault CA into the JVM truststore + start both Nessie instances."
}
variable "enable_iceberg_catalog_bootstrap" {
  type        = bool
  default     = true
  description = "role-overlay-iceberg-catalog-bootstrap.tf -- exit gate: create a namespace + table via the Iceberg REST API (Nessie), verify metadata/data land in MinIO s3://warehouse."
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
variable "vault_agent_iceberg_creds_dir" {
  type    = string
  default = "$HOME/.nexus"
}
variable "vault_pki_ca_bundle_path" {
  type    = string
  default = "$HOME/.nexus/vault-ca-bundle.crt"
}
variable "vault_pki_iceberg_role_name" {
  type    = string
  default = "iceberg-server"
}

# ─── KV creds (sticky-seeded by the security env) ─────────────────────────
variable "kv_pg_superuser_password_path" {
  type    = string
  default = "nexus/lakehouse/iceberg/pg-superuser-password"
}
variable "kv_pg_replication_password_path" {
  type    = string
  default = "nexus/lakehouse/iceberg/pg-replication-password"
}
variable "kv_nessie_db_password_path" {
  type    = string
  default = "nexus/lakehouse/iceberg/nessie-db-password"
}
variable "kv_minio_app_access_key_path" {
  type        = string
  default     = "nexus/lakehouse/minio/app-access-key"
  description = "MinIO least-priv app access key (seeded at 0.L.1). Nessie's S3 client uses it for the warehouse."
}
variable "kv_minio_app_secret_key_path" {
  type    = string
  default = "nexus/lakehouse/minio/app-secret-key"
}

# ─── Catalog topology ─────────────────────────────────────────────────────
variable "iceberg_db_vip" {
  type        = string
  default     = "192.168.70.151"
  description = "keepalived VRRP VIP for the catalog PG front door (iceberg-db.nexus.lab). Nessie connects here; floats to whichever PG node is primary."
}
variable "iceberg_db_dns_name" {
  type    = string
  default = "iceberg-db.nexus.lab"
}
variable "nessie_db_name" {
  type    = string
  default = "nessie"
}
variable "nessie_db_user" {
  type    = string
  default = "nessie"
}
variable "iceberg_warehouse_bucket" {
  type        = string
  default     = "warehouse"
  description = "MinIO bucket holding the Iceberg warehouse (s3://warehouse), created at 0.L.1."
}
variable "minio_s3_endpoint" {
  type    = string
  default = "https://minio.nexus.lab:9000"
}
variable "iceberg_rest_dns_name" {
  type    = string
  default = "iceberg.nexus.lab"
}
