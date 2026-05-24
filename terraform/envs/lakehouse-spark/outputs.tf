output "spark_topology" {
  description = "Phase 0.L.3 Spark standalone HA cluster topology."
  value = {
    masters = {
      spark-master-1 = { service_ip = "192.168.70.140", backplane_ip = "192.168.10.140", rpc = 7077, ui = 8080 }
      spark-master-2 = { service_ip = "192.168.70.153", backplane_ip = "192.168.10.153", rpc = 7077, ui = 8080 }
    }
    workers = {
      spark-worker-1 = { service_ip = "192.168.70.145", backplane_ip = "192.168.10.145", ui = 8081 }
      spark-worker-2 = { service_ip = "192.168.70.146", backplane_ip = "192.168.10.146", ui = 8081 }
      spark-worker-3 = { service_ip = "192.168.70.154", backplane_ip = "192.168.10.154", ui = 8081 }
    }
    zookeeper = {
      zookeeper-1 = { backplane_ip = "192.168.10.155", client = 2181 }
      zookeeper-2 = { backplane_ip = "192.168.10.156", client = 2181 }
      zookeeper-3 = { backplane_ip = "192.168.10.157", client = 2181 }
    }
    master_url    = "spark://192.168.70.140:7077,192.168.70.153:7077 (HA, ZooKeeper-elected; no VIP)"
    ui_front_door = "http://spark-master.nexus.lab:8080 (round-robin over the 2 masters; the standby returns a redirect/STANDBY status)"
    recovery_mode = "ZOOKEEPER -> zookeeper-1/2/3 backplane :2181 (the one deliberate Apache-ZK exception; ADR-0035)"
    catalog       = "Iceberg REST -> Nessie https://iceberg.nexus.lab:19120/iceberg/ (0.L.2)"
    warehouse     = "s3a://warehouse + s3a://spark-events (MinIO; https://minio.nexus.lab:9000)"
  }
}

output "next_step" {
  value = <<-EOT
    Phase 0.L.3 envs/lakehouse-spark/ state -- 8 VMs (2 Spark masters + 3 workers + 3 ZooKeeper).
    Apply order:
      1. nexus-infra-vmware: foundation apply (reservations :AA-:AE; spark-master.nexus.lab -> .140/.153).
      2. nexus-infra-vmware: security apply   (spark-server PKI role + 5 AppRole sidecars + KV seed nexus/lakehouse/spark/auth-secret).
      3. packer build packer/lakehouse-spark-node + packer/lakehouse-zookeeper-node.
      4. This env:           pwsh -File scripts/lakehouse-spark.ps1 apply.
      5. Smoke:              pwsh -File scripts/smoke-0.L.3.ps1.
    Requires MinIO (0.L.1) + the Iceberg catalog (0.L.2) up (the S3A warehouse + the Nessie REST catalog).
  EOT
}
