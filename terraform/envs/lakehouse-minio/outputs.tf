# nexus-infra-lakehouse / terraform / envs / lakehouse-minio / outputs.tf

output "minio_topology" {
  description = "MinIO distributed erasure-coded cluster: 4 nodes (.141-.144). Client S3 endpoint via round-robin DNS minio.nexus.lab:9000 (no VIP -- ADR-0031/0033). Inter-node erasure/heal traffic on the VMnet10 backplane (.10.141-.144:9000). Console minio-N.nexus.lab:9001."
  value = {
    front_door = "https://minio.nexus.lab:9000 (round-robin over the 4 nodes; no VIP -- ADR-0033)"
    nodes = {
      for n in ["minio-1", "minio-2", "minio-3", "minio-4"] : n => {
        service_ip   = lookup({ "minio-1" = "192.168.70.141", "minio-2" = "192.168.70.142", "minio-3" = "192.168.70.143", "minio-4" = "192.168.70.144" }, n)
        backplane_ip = lookup({ "minio-1" = "192.168.10.141", "minio-2" = "192.168.10.142", "minio-3" = "192.168.10.143", "minio-4" = "192.168.10.144" }, n)
        s3_port      = 9000
        console_port = 9001
        data_drive   = "/mnt/minio/data (xfs, label minio-data)"
      }
    }
    erasure  = "MINIO_VOLUMES=https://192.168.10.{141...144}:9000/mnt/minio/data (4-drive set, default EC:2 -> tolerates 1 node down read-write, 2 nodes down read-only)"
    warehouse = "s3://${var.minio_warehouse_bucket} (Iceberg warehouse; consumed by 0.L.2 catalog + 0.L.3 Spark)"
  }
}

output "next_step" {
  value = <<-EOT
    Phase 0.L.1 envs/lakehouse-minio/ state -- 4 MinIO VMs (distributed EC) + overlays.
    Apply order:
      1. nexus-infra-vmware: foundation apply (dhcp :9A-:9D + round-robin DNS minio.nexus.lab over .141-.144).
      2. nexus-infra-vmware: security apply   (minio-server PKI role + 4 AppRole sidecars + KV seeds nexus/lakehouse/minio/*).
      3. packer build packer/lakehouse-minio-node.
      4. This env:           pwsh -File scripts/lakehouse-minio.ps1 apply.
      5. Smoke:              pwsh -File scripts/smoke-0.L.1.ps1.
    The MinIO cluster is the storage foundation for 0.L.2 (Iceberg warehouse), 0.L.3 (Spark
    spark-events + Iceberg reads), and 0.L.5 (StarRocks shared-data storage volume).
  EOT
}
