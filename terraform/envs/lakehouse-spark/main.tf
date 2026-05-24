# nexus-infra-lakehouse / terraform / envs / lakehouse-spark / main.tf
#
# Per-cluster Terraform state for the Spark standalone HA cluster (Phase 0.L.3):
#   - spark-master-1 (.140) + spark-master-2 (.153)  (HA pair, ZooKeeper-elected;
#     recoveryMode=ZOOKEEPER; multi-master URL; no VIP -- ADR-0035)
#   - spark-worker-1/2/3 (.145/.146/.154)
#   - zookeeper-1/2/3 (.155-.157)  (3-node ensemble; backplane-only; the master
#     HA election quorum -- the platform's one deliberate Apache-ZK exception)
#
# Cross-env prerequisites (run in nexus-infra-vmware FIRST):
#   1. foundation env applied (reservations :AA-:AE; spark-master.nexus.lab -> .140/.153).
#   2. security env applied (spark-server PKI role + 5 AppRole sidecars + KV seed
#      nexus/lakehouse/spark/auth-secret). ZooKeeper has NO Vault footprint.
#   3. Packer templates built (lakehouse-spark-node + lakehouse-zookeeper-node).
#   4. MinIO (0.L.1) + Iceberg catalog (0.L.2) up (the S3A warehouse + Nessie REST).
#
# Apply order:
#   modules (8) -> nftables-backplane -> vault-agents (5 spark) -> tls (5 spark)
#   -> zk-ensemble (zoo.cfg + myid + start + quorum)
#   -> spark-config (spark-env/defaults + recoveryMode=ZOOKEEPER + start role unit)
#   -> spark-cluster-bootstrap (masters ALIVE + workers registered + S3A/Iceberg; exit gate)

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

# ─── Spark HA masters ─────────────────────────────────────────────────────
module "spark_master_1" {
  source = "../../modules/vm"
  count  = var.enable_spark_master_1 ? 1 : 0

  vm_name           = "spark-master-1"
  template_vmx_path = "${var.template_root}/lakehouse-spark-node/lakehouse-spark-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/spark-master-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_spark_master_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_spark_master_1_secondary
}

module "spark_master_2" {
  source = "../../modules/vm"
  count  = var.enable_spark_master_2 ? 1 : 0

  vm_name           = "spark-master-2"
  template_vmx_path = "${var.template_root}/lakehouse-spark-node/lakehouse-spark-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/spark-master-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_spark_master_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_spark_master_2_secondary
}

# ─── Spark workers ────────────────────────────────────────────────────────
module "spark_worker_1" {
  source = "../../modules/vm"
  count  = var.enable_spark_worker_1 ? 1 : 0

  vm_name           = "spark-worker-1"
  template_vmx_path = "${var.template_root}/lakehouse-spark-node/lakehouse-spark-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/spark-worker-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_spark_worker_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_spark_worker_1_secondary
}

module "spark_worker_2" {
  source = "../../modules/vm"
  count  = var.enable_spark_worker_2 ? 1 : 0

  vm_name           = "spark-worker-2"
  template_vmx_path = "${var.template_root}/lakehouse-spark-node/lakehouse-spark-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/spark-worker-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_spark_worker_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_spark_worker_2_secondary
}

module "spark_worker_3" {
  source = "../../modules/vm"
  count  = var.enable_spark_worker_3 ? 1 : 0

  vm_name           = "spark-worker-3"
  template_vmx_path = "${var.template_root}/lakehouse-spark-node/lakehouse-spark-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/spark-worker-3"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_spark_worker_3_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_spark_worker_3_secondary
}

# ─── ZooKeeper ensemble (Spark master-HA quorum) ──────────────────────────
module "zookeeper_1" {
  source = "../../modules/vm"
  count  = var.enable_zookeeper_1 ? 1 : 0

  vm_name           = "zookeeper-1"
  template_vmx_path = "${var.template_root}/lakehouse-zookeeper-node/lakehouse-zookeeper-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/zookeeper-1"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_zookeeper_1_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_zookeeper_1_secondary
}

module "zookeeper_2" {
  source = "../../modules/vm"
  count  = var.enable_zookeeper_2 ? 1 : 0

  vm_name           = "zookeeper-2"
  template_vmx_path = "${var.template_root}/lakehouse-zookeeper-node/lakehouse-zookeeper-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/zookeeper-2"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_zookeeper_2_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_zookeeper_2_secondary
}

module "zookeeper_3" {
  source = "../../modules/vm"
  count  = var.enable_zookeeper_3 ? 1 : 0

  vm_name           = "zookeeper-3"
  template_vmx_path = "${var.template_root}/lakehouse-zookeeper-node/lakehouse-zookeeper-node.vmx"
  vm_output_dir     = "${var.vm_output_dir_root}/08-spark/zookeeper-3"
  vmrun_path        = var.vmrun_path

  vnet           = var.vnet_primary
  mac_address    = var.mac_zookeeper_3_primary
  vnet_secondary = var.vnet_secondary
  mac_secondary  = var.mac_zookeeper_3_secondary
}
