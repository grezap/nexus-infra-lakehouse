/*
 * lakehouse-spark-node -- NexusPlatform Apache Spark standalone node template
 * (Phase 0.L.3).
 *
 * Per-engine template. Installs JDK 21 + Apache Spark (bin-hadoop3) + the S3A
 * connector (hadoop-aws + aws-java-sdk-bundle) + the Iceberg Spark runtime, so a
 * single image serves BOTH Spark roles in the 08-spark tier per vms.yaml:
 *   - spark-master-1 (.140) + spark-master-2 (.153)  -- HA pair (ZK-elected)
 *   - spark-worker-1/2/3 (.145/.146/.154)
 * Master HA is coordinated by the 3-node ZooKeeper ensemble (zookeeper-1..3).
 *
 *   - OS: Debian 13. Default RAM 4 GB (workers run executors; ADR-0035).
 *   - Dual-NIC: master<->worker RPC + Web UIs on VMnet11; Spark<->ZooKeeper
 *     election traffic on the VMnet10 backplane.
 *
 * BOTH nexus-spark-master.service AND nexus-spark-worker.service are delivered
 * DISABLED. The Terraform spark-config overlay renders spark-env.sh +
 * spark-defaults.conf (recoveryMode=ZOOKEEPER, multi-master URL, S3A->MinIO,
 * Iceberg REST catalog->Nessie, spark.authenticate secret, UI TLS) then enables
 * exactly ONE role unit per node from NEXUS_ROLE.
 *
 * Build:   cd packer/lakehouse-spark-node; packer init .; packer build .
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware  = { version = ">= 1.0.11", source = "github.com/hashicorp/vmware" }
    ansible = { version = ">= 1.1.1", source = "github.com/hashicorp/ansible" }
  }
}

source "vmware-iso" "spark-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type = "debian12-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0

  network_adapter_type = "vmxnet3"
  network              = "nat"

  version = "20"

  http_directory = "http"
  boot_wait      = var.boot_wait
  boot_command = [
    "<esc><wait>",
    "auto ",
    "url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "language=en country=US locale=en_US.UTF-8 keymap=us ",
    "hostname=${var.vm_name} domain=nexus.local ",
    "priority=critical ",
    "interface=auto ",
    "<enter>"
  ]

  communicator           = "ssh"
  ssh_username           = var.ssh_username
  ssh_password           = var.ssh_password
  ssh_timeout            = var.ssh_timeout
  ssh_handshake_attempts = 200

  shutdown_command = "echo '${var.ssh_password}' | sudo -S -E shutdown -P now"
  shutdown_timeout = "5m"

  headless        = true
  skip_compaction = false

  vmx_remove_ethernet_interfaces = true

  vmx_data = {
    "annotation"           = "lakehouse-spark-node template (Phase 0.L.3) -- built by Packer; Apache Spark ${var.spark_version} (bin-hadoop3) + Iceberg ${var.iceberg_version} + S3A on ${var.jdk_package}"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "spark-node"
  sources = ["source.vmware-iso.spark-node"]

  provisioner "file" {
    source      = "files/nftables.conf"
    destination = "/tmp/nftables.conf"
  }
  provisioner "file" {
    source      = "files/chrony.conf"
    destination = "/tmp/chrony.conf"
  }

  provisioner "shell" {
    inline = [
      "echo 'Waiting for systemd to settle...'",
      "sudo systemctl is-system-running --wait || true",
      "echo 'Installing Ansible + prerequisites...'",
      "sudo apt-get update -qq",
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip apt-transport-https"
    ]
  }

  provisioner "ansible-local" {
    playbook_file = "ansible/playbook.yml"
    role_paths = [
      "../_shared/ansible/roles/nexus_identity",
      "../_shared/ansible/roles/nexus_network",
      "../_shared/ansible/roles/nexus_firewall",
      "../_shared/ansible/roles/nexus_observability",
      "../_shared/ansible/roles/lakehouse_firstboot",
      "ansible/roles/lakehouse_spark",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "lakehouse_spark_version=${var.spark_version}",
      "--extra-vars", "lakehouse_spark_download_url=${var.spark_download_url}",
      "--extra-vars", "lakehouse_iceberg_runtime_url=${var.iceberg_runtime_url}",
      "--extra-vars", "lakehouse_iceberg_aws_bundle_url=${var.iceberg_aws_bundle_url}",
      "--extra-vars", "lakehouse_hadoop_aws_url=${var.hadoop_aws_url}",
      "--extra-vars", "lakehouse_aws_sdk_bundle_url=${var.aws_sdk_bundle_url}",
      "--extra-vars", "lakehouse_jdk_package=${var.jdk_package}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- lakehouse-spark-node post-install checks ---'",
      "test -x /opt/spark/bin/spark-class",
      "test -s /opt/spark/jars/iceberg-spark-runtime-3.5_2.12-${var.iceberg_version}.jar",
      "test -s /opt/spark/jars/iceberg-aws-bundle-${var.iceberg_version}.jar",
      "test -s /opt/spark/jars/hadoop-aws-${var.hadoop_aws_version}.jar",
      "ls /opt/spark/jars/aws-java-sdk-bundle-*.jar",
      "test -x /usr/lib/jvm/java-21-openjdk-amd64/bin/java",
      "systemctl cat nexus-spark-master.service > /dev/null",
      "systemctl cat nexus-spark-worker.service > /dev/null",
      "systemctl cat lakehouse-node-firstboot.service > /dev/null",
      "systemctl is-enabled lakehouse-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "systemctl is-enabled nexus-spark-master.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: nexus-spark-master.service not disabled at bake' && exit 1)",
      "systemctl is-enabled nexus-spark-worker.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: nexus-spark-worker.service not disabled at bake' && exit 1)",
      "id spark",
      "echo '--- cleanup ---'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id && sudo ln -s /etc/machine-id /var/lib/dbus/machine-id",
      "sudo rm -f /var/lib/systemd/random-seed",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "history -c || true",
      "sudo rm -f /home/${var.ssh_username}/.bash_history || true"
    ]
  }

  post-processor "manifest" {
    output     = "${var.output_directory}/packer-manifest.json"
    strip_path = true
  }
}
