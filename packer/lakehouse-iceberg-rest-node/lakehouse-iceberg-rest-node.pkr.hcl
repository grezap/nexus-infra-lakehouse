/*
 * lakehouse-iceberg-rest-node -- NexusPlatform Iceberg REST catalog (Nessie)
 * node template (Phase 0.L.2).
 *
 * Per-engine template. Installs JDK 21 + the Project Nessie quarkus-runner JAR.
 * Two instances clone into the 08-spark tier per vms.yaml:
 *   - iceberg-rest-1 (.147) + iceberg-rest-2 (.148)
 * Both are stateless Nessie servers fronted by round-robin DNS
 * iceberg.nexus.lab; state lives in the dedicated iceberg-pg master-replica
 * (JDBC) + the MinIO warehouse (S3). Nessie speaks the Iceberg REST API at
 * :19120/iceberg/ (ADR-0034).
 *
 *   - OS: Debian 13. Default RAM 2 GB (feedback_prefer_less_memory.md).
 *   - Dual-NIC (uniform with the tier); Nessie's traffic is VMnet11 only
 *     (clients -> :19120; Nessie -> iceberg-db VIP :5432 + minio.nexus.lab).
 *
 * nexus-nessie.service is delivered DISABLED. The Terraform nessie-config
 * overlay renders /etc/nexus-iceberg-rest/nessie.env (JDBC -> iceberg-db.nexus.lab
 * + S3 -> minio.nexus.lab + TLS) then enables + starts both instances.
 *
 * Build:   cd packer/lakehouse-iceberg-rest-node; packer init .; packer build .
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware  = { version = ">= 1.0.11", source = "github.com/hashicorp/vmware" }
    ansible = { version = ">= 1.1.1", source = "github.com/hashicorp/ansible" }
  }
}

source "vmware-iso" "iceberg-rest-node" {
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
    "annotation"           = "lakehouse-iceberg-rest-node template (Phase 0.L.2) -- built by Packer; Project Nessie ${var.nessie_version} (Iceberg REST catalog) on ${var.jdk_package}"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "iceberg-rest-node"
  sources = ["source.vmware-iso.iceberg-rest-node"]

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
      "ansible/roles/lakehouse_iceberg_rest",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "lakehouse_nessie_version=${var.nessie_version}",
      "--extra-vars", "lakehouse_nessie_download_url=${var.nessie_download_url}",
      "--extra-vars", "lakehouse_jdk_package=${var.jdk_package}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- lakehouse-iceberg-rest-node post-install checks ---'",
      "test -s /opt/nessie/nessie-quarkus-runner.jar",
      "test -x /usr/lib/jvm/java-21-openjdk-amd64/bin/java",
      "systemctl cat nexus-nessie.service > /dev/null",
      "systemctl cat lakehouse-node-firstboot.service > /dev/null",
      "systemctl is-enabled lakehouse-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "systemctl is-enabled nexus-nessie.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: nexus-nessie.service not disabled at bake' && exit 1)",
      "id nessie",
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
