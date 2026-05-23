# nexus-infra-lakehouse / terraform / envs / lakehouse-minio / main.tf
#
# Per-cluster Terraform state for the MinIO cluster (4 nodes: minio-1..4 at
# .141-.144). Per-cluster state + per-engine template canon
# (feedback_per_cluster_state_per_engine_template.md).
#
# Cross-env prerequisites (run in nexus-infra-vmware FIRST):
#   1. foundation env applied (dhcp-host reservations for the 4 MinIO MACs
#      :9A-:9D + round-robin minio.nexus.lab over .141-.144).
#   2. security env applied (minio-server PKI role + 4 per-host AppRole sidecars
#      + KV sticky-seeds at nexus/lakehouse/minio/{root-user,root-password,
#      app-access-key,app-secret-key}).
#   3. Packer template built (lakehouse-minio-node).
#
# Apply order:
#   module.minio_1..4                       (clone + power on; firstboot inside)
#   -> null_resource.minio_nftables_backplane
#   -> null_resource.minio_vault_agent      (for_each, 4 nodes)
#   -> null_resource.minio_tls              (for_each, 4 nodes)
#   -> null_resource.minio_config           (render minio.conf + enable+start all 4 as one erasure set)
#   -> null_resource.minio_bucket_bootstrap (mc alias + create warehouse buckets + app user/policy + exit gate)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── MinIO distributed erasure-coded cluster (4 nodes) ────────────────────
module "minio_1" {
  source = "../../modules/vm"
  count  = var.enable_minio_1 ? 1 : 0

  vm_name           = "minio-1"
  template_vmx_path = "${var.template_root}/lakehouse-minio-node/lakehouse-minio-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/minio-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_minio_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_minio_1_secondary
}

module "minio_2" {
  source = "../../modules/vm"
  count  = var.enable_minio_2 ? 1 : 0

  vm_name           = "minio-2"
  template_vmx_path = "${var.template_root}/lakehouse-minio-node/lakehouse-minio-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/minio-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_minio_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_minio_2_secondary
}

module "minio_3" {
  source = "../../modules/vm"
  count  = var.enable_minio_3 ? 1 : 0

  vm_name           = "minio-3"
  template_vmx_path = "${var.template_root}/lakehouse-minio-node/lakehouse-minio-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/minio-3"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_minio_3_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_minio_3_secondary
}

module "minio_4" {
  source = "../../modules/vm"
  count  = var.enable_minio_4 ? 1 : 0

  vm_name           = "minio-4"
  template_vmx_path = "${var.template_root}/lakehouse-minio-node/lakehouse-minio-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/minio-4"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_minio_4_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_minio_4_secondary
}
