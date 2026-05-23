# nexus-infra-lakehouse / terraform / envs / lakehouse-iceberg / main.tf
#
# Per-cluster Terraform state for the Iceberg REST catalog cluster (Phase 0.L.2):
#   - iceberg-pg-1 (.149) PRIMARY + iceberg-pg-2 (.150) REPLICA  (PG17 streaming
#     replication + keepalived VRRP VIP iceberg-db.nexus.lab .151)
#   - iceberg-rest-1 (.147) + iceberg-rest-2 (.148)  (Project Nessie, round-robin
#     iceberg.nexus.lab; warehouse in MinIO s3://warehouse; metadata in the PG pair)
#
# Cross-env prerequisites (run in nexus-infra-vmware FIRST):
#   1. foundation env applied (reservations :A0-:A3; round-robin iceberg.nexus.lab
#      -> .147/.148 + iceberg-db.nexus.lab -> VIP .151).
#   2. security env applied (iceberg-server PKI role + 4 AppRole sidecars + KV
#      seeds at nexus/lakehouse/iceberg/*).
#   3. Packer templates built (lakehouse-iceberg-pg-node + lakehouse-iceberg-rest-node).
#   4. MinIO (0.L.1) up (the warehouse) -- nexus-lakehouse-app S3 key in KV.
#
# Apply order:
#   modules (4) -> nftables-backplane -> vault-agents (4) -> tls (4)
#   -> pg-replication (primary config + replica basebackup + keepalived VIP)
#   -> nessie-config (render nessie.env + start both REST instances)
#   -> catalog-bootstrap (create namespace/table via Iceberg REST; exit gate)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── Iceberg catalog PostgreSQL pair (primary + replica) ──────────────────
module "iceberg_pg_1" {
  source = "../../modules/vm"
  count  = var.enable_iceberg_pg_1 ? 1 : 0

  vm_name           = "iceberg-pg-1"
  template_vmx_path = "${var.template_root}/lakehouse-iceberg-pg-node/lakehouse-iceberg-pg-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/iceberg-pg-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_iceberg_pg_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_iceberg_pg_1_secondary
}

module "iceberg_pg_2" {
  source = "../../modules/vm"
  count  = var.enable_iceberg_pg_2 ? 1 : 0

  vm_name           = "iceberg-pg-2"
  template_vmx_path = "${var.template_root}/lakehouse-iceberg-pg-node/lakehouse-iceberg-pg-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/iceberg-pg-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_iceberg_pg_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_iceberg_pg_2_secondary
}

# ─── Iceberg REST catalog (Nessie) HA pair ────────────────────────────────
module "iceberg_rest_1" {
  source = "../../modules/vm"
  count  = var.enable_iceberg_rest_1 ? 1 : 0

  vm_name           = "iceberg-rest-1"
  template_vmx_path = "${var.template_root}/lakehouse-iceberg-rest-node/lakehouse-iceberg-rest-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/iceberg-rest-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_iceberg_rest_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_iceberg_rest_1_secondary
}

module "iceberg_rest_2" {
  source = "../../modules/vm"
  count  = var.enable_iceberg_rest_2 ? 1 : 0

  vm_name           = "iceberg-rest-2"
  template_vmx_path = "${var.template_root}/lakehouse-iceberg-rest-node/lakehouse-iceberg-rest-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/iceberg-rest-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_iceberg_rest_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_iceberg_rest_2_secondary
}
