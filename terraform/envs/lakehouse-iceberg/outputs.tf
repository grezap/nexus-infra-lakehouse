# nexus-infra-lakehouse / terraform / envs / lakehouse-iceberg / outputs.tf

output "iceberg_topology" {
  description = "Iceberg REST catalog (Nessie) + dedicated PG master-replica HA (ADR-0034). Clients use the Iceberg REST endpoint https://iceberg.nexus.lab:19120/iceberg/; Nessie stores metadata in PG (via the iceberg-db.nexus.lab VRRP VIP) + warehouse data in MinIO."
  value = {
    rest_front_door = "https://iceberg.nexus.lab:19120/iceberg/ (round-robin over the 2 Nessie instances; no VIP -- ADR-0031)"
    db_front_door   = "iceberg-db.nexus.lab:5432 (keepalived VRRP VIP ${var.iceberg_db_vip} -> current PG primary)"
    warehouse       = "s3://${var.iceberg_warehouse_bucket} (in MinIO; ${var.minio_s3_endpoint})"
    pg = {
      "iceberg-pg-1" = { role = "PRIMARY (keepalived MASTER)", service_ip = "192.168.70.149", backplane_ip = "192.168.10.149" }
      "iceberg-pg-2" = { role = "REPLICA (keepalived BACKUP)", service_ip = "192.168.70.150", backplane_ip = "192.168.10.150" }
    }
    rest = {
      "iceberg-rest-1" = { service_ip = "192.168.70.147", port = 19120 }
      "iceberg-rest-2" = { service_ip = "192.168.70.148", port = 19120 }
    }
  }
}

output "next_step" {
  value = <<-EOT
    Phase 0.L.2 envs/lakehouse-iceberg/ state -- 4 VMs (2 PG + 2 Nessie REST).
    Apply order:
      1. nexus-infra-vmware: foundation apply (reservations :A0-:A3; iceberg.nexus.lab -> .147/.148 + iceberg-db.nexus.lab -> VIP .151).
      2. nexus-infra-vmware: security apply   (iceberg-server PKI role + 4 AppRole sidecars + KV seeds nexus/lakehouse/iceberg/*).
      3. packer build packer/lakehouse-iceberg-pg-node + packer/lakehouse-iceberg-rest-node.
      4. This env:           pwsh -File scripts/lakehouse-iceberg.ps1 apply.
      5. Smoke:              pwsh -File scripts/smoke-0.L.2.ps1.
    Requires MinIO (0.L.1) up (the s3://warehouse). The Iceberg catalog is the
    metadata layer for 0.L.3 Spark (writes Iceberg tables) + 0.L.5 StarRocks.
  EOT
}
