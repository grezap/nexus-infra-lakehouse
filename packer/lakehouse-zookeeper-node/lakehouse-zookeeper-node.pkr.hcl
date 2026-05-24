/*
 * lakehouse-zookeeper-node -- NexusPlatform Apache ZooKeeper node template
 * (Phase 0.L.3).
 *
 * Per-engine template. Installs JDK 21 + Apache ZooKeeper. Three instances clone
 * into the 08-spark tier per vms.yaml:
 *   - zookeeper-1/2/3 (.155-.157)
 * The 3-node ensemble is the coordination quorum that elects the active Spark
 * master (recoveryMode=ZOOKEEPER, ADR-0035). ZooKeeper is the platform's ONE
 * deliberate Apache-ZK exception (Kafka is KRaft, ClickHouse uses Keeper) --
 * Spark standalone's only mainstream-tested master-HA mechanism.
 *
 *   - OS: Debian 13. Default RAM 2 GB (ZK holds only election metadata).
 *   - Dual-NIC: the ensemble (client 2181 + quorum 2888/3888) runs on the
 *     VMnet10 backplane ONLY -- nftables trusts 192.168.10.0/24 (network
 *     segmentation is the coordination-layer security boundary, ADR-0035).
 *
 * nexus-zookeeper.service is delivered DISABLED. The Terraform zk-ensemble
 * overlay renders /etc/nexus-zookeeper/zoo.cfg (server.1/2/3 on backplane IPs) +
 * /var/lib/zookeeper/myid (from NEXUS_ZK_ID), then enables + starts all three.
 *
 * Build:   cd packer/lakehouse-zookeeper-node; packer init .; packer build .
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware  = { version = ">= 1.0.11", source = "github.com/hashicorp/vmware" }
    ansible = { version = ">= 1.1.1", source = "github.com/hashicorp/ansible" }
  }
}

source "vmware-iso" "zookeeper-node" {
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
    "annotation"           = "lakehouse-zookeeper-node template (Phase 0.L.3) -- built by Packer; Apache ZooKeeper ${var.zookeeper_version} on ${var.jdk_package}"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "zookeeper-node"
  sources = ["source.vmware-iso.zookeeper-node"]

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
      "ansible/roles/lakehouse_zookeeper",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "lakehouse_zookeeper_version=${var.zookeeper_version}",
      "--extra-vars", "lakehouse_zookeeper_download_url=${var.zookeeper_download_url}",
      "--extra-vars", "lakehouse_jdk_package=${var.jdk_package}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- lakehouse-zookeeper-node post-install checks ---'",
      "test -x /opt/zookeeper/bin/zkServer.sh",
      "test -s /etc/nexus-zookeeper/logback.xml",
      "test -x /usr/lib/jvm/java-21-openjdk-amd64/bin/java",
      "systemctl cat nexus-zookeeper.service > /dev/null",
      "systemctl cat lakehouse-node-firstboot.service > /dev/null",
      "systemctl is-enabled lakehouse-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "systemctl is-enabled nexus-zookeeper.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: nexus-zookeeper.service not disabled at bake' && exit 1)",
      "id zookeeper",
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
