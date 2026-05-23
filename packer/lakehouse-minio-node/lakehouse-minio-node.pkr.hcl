/*
 * lakehouse-minio-node -- NexusPlatform MinIO node template (Phase 0.L.1).
 *
 * Per-engine template (feedback_per_cluster_state_per_engine_template.md).
 * Installs the MinIO server + mc client (single Go binaries, no JVM), creates
 * the minio system account, and attaches a dedicated data VMDK formatted xfs
 * (label minio-data, mounted /mnt/minio/data) so erasure coding runs on a
 * dedicated drive rather than the root filesystem.
 *
 * Four instances clone into the 08-spark tier per vms.yaml:
 *   - 0.L.1: minio-1/2/3/4 (distributed erasure-coded object store at .141-.144)
 *
 *   - OS: Debian 13. Default RAM 2 GB (feedback_prefer_less_memory.md).
 *   - Dual-NIC: ethernet0 = VMnet11 (client S3 API 9000 + console 9001),
 *     ethernet1 = VMnet10 (backplane: inter-node erasure/heal traffic on 9000).
 *
 * nexus-minio.service is delivered DISABLED. The Terraform overlays render
 * /etc/nexus-minio/minio.conf (MINIO_VOLUMES across the 4 backplane IPs,
 * MINIO_ROOT_USER/PASSWORD from Vault KV, TLS certs dir) then enable + start
 * all 4 nodes together so they form the erasure set. firstboot writes the
 * node identity.
 *
 * Build:   cd packer/lakehouse-minio-node; packer init .; packer build .
 */

packer {
  required_version = ">= 1.11.0"
  required_plugins {
    vmware  = { version = ">= 1.0.11", source = "github.com/hashicorp/vmware" }
    ansible = { version = ">= 1.1.1", source = "github.com/hashicorp/ansible" }
  }
}

source "vmware-iso" "minio-node" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  guest_os_type = "debian12-64"
  cpus          = var.cpus
  memory        = var.memory_mb
  disk_size     = var.disk_gb * 1024
  disk_type_id  = 0

  # Dedicated data disk for the MinIO erasure set (appears as /dev/sdb at bake;
  # preseed pins /dev/sda as root). Formatted xfs (label minio-data) by the role.
  disk_additional_size = [var.data_disk_gb * 1024]

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
    "annotation"           = "lakehouse-minio-node template (Phase 0.L.1) -- built by Packer; MinIO ${var.minio_version} + mc (distributed erasure-coded object store)"
    "tools.upgrade.policy" = "useGlobal"
  }
}

build {
  name    = "minio-node"
  sources = ["source.vmware-iso.minio-node"]

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
      "sudo apt-get install -y -qq python3 python3-apt sudo ansible curl ca-certificates gnupg openssl jq unzip apt-transport-https xfsprogs"
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
      "ansible/roles/lakehouse_minio",
    ]
    extra_arguments = [
      "--extra-vars", "target_user=${var.ssh_username}",
      "--extra-vars", "lakehouse_minio_version=${var.minio_version}",
      "--extra-vars", "lakehouse_minio_download_url=${var.minio_download_url}",
      "--extra-vars", "lakehouse_mc_download_url=${var.mc_download_url}",
    ]
  }

  provisioner "shell" {
    inline = [
      "echo '--- lakehouse-minio-node post-install checks ---'",
      "test -x /usr/local/bin/minio",
      "test -x /usr/local/bin/mc",
      "systemctl cat nexus-minio.service > /dev/null",
      "systemctl cat lakehouse-node-firstboot.service > /dev/null",
      "systemctl is-enabled lakehouse-node-firstboot",
      "systemctl is-enabled ssh",
      "systemctl is-enabled nftables",
      "systemctl is-enabled chrony",
      "systemctl is-enabled prometheus-node-exporter",
      "systemctl is-enabled nexus-minio.service 2>&1 | grep -qE '^(disabled|masked)$' || (echo 'ERROR: nexus-minio.service not disabled at bake' && exit 1)",
      "id minio",
      "findmnt /mnt/minio/data > /dev/null || (echo 'ERROR: /mnt/minio/data not mounted (data disk format failed)' && exit 1)",
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
