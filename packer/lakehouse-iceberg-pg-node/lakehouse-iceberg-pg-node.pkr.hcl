/*
 * lakehouse-iceberg-pg-node -- NexusPlatform Iceberg catalog PostgreSQL node
 * template (Phase 0.L.2).
 *
 * Per-engine template. Installs PostgreSQL 17 (PGDG) + keepalived. Two
 * instances clone into the 08-spark tier per vms.yaml:
 *   - iceberg-pg-1 (.149) PRIMARY  + iceberg-pg-2 (.150) REPLICA
 * They form a streaming-replication pair with a keepalived VRRP VIP
 * (iceberg-db.nexus.lab .151) fronting the current primary -- the dedicated,
 * HA metadata store for the Nessie Iceberg REST catalog (ADR-0034).
 *
 *   - OS: Debian 13. Default RAM 2 GB (feedback_prefer_less_memory.md).
 *   - Single disk (no dedicated data disk -- catalog metadata is small).
 *   - Dual-NIC: ethernet0 = VMnet11 (client :5432 + VRRP), ethernet1 = VMnet10
 *     (backplane: streaming replication).
 *
 * The stock postgresql@17-main service is delivered DISABLED. The Terraform
 * pg-replication overlay configures postgresql.conf/pg_hba.conf, creates the
 * replication + nessie roles + the nessie DB (primary), runs pg_basebackup
 * (replica), and renders keepalived.conf, then enables the services. firstboot
 * writes the node identity incl. NEXUS_PG_ROLE (primary/replica).
 *
 * Build:   cd packer/lakehouse-iceberg-pg-node; packer init .; packer build .
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware  = { version = ">= 1.0.11", source = "github.com/hashicorp/vmware" }
    ansible = { version = ">= 1.1.1", source = "github.com/hashicorp/ansible" }
  }
}

source "vmware-iso" "iceberg-pg-node" {
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
    "annotation"           = "lakehouse-iceberg-pg-node template (Phase 0.L.2) -- built by Packer; PostgreSQL ${var.pg_version} (PGDG) + keepalived; Iceberg catalog metadata store (master-replica HA)"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "iceberg-pg-node"
  sources = ["source.vmware-iso.iceberg-pg-node"]

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
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip apt-transport-https lsb-release"
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
      "ansible/roles/lakehouse_iceberg_pg",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "lakehouse_pg_version=${var.pg_version}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- lakehouse-iceberg-pg-node post-install checks ---'",
      "test -x /usr/lib/postgresql/${var.pg_version}/bin/postgres",
      "test -x /usr/sbin/keepalived",
      "systemctl cat lakehouse-node-firstboot.service > /dev/null",
      "systemctl is-enabled lakehouse-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "systemctl is-enabled postgresql.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: postgresql.service not disabled at bake' && exit 1)",
      "systemctl is-enabled keepalived.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: keepalived.service not disabled at bake' && exit 1)",
      "id postgres",
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
