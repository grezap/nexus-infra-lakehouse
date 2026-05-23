/*
 * lakehouse-minio-node -- Packer template variables (Phase 0.L.1)
 *
 * Per-engine template: installs the MinIO server + mc client from the official
 * single-binary release channel. No JVM. A dedicated data VMDK holds the
 * erasure-set drive.
 */

variable "vm_name" {
  type        = string
  default     = "lakehouse-minio-node"
  description = "VM display name + output .vmx basename. Per-clone names (minio-1..4) set by terraform/envs/lakehouse-minio/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/lakehouse-minio-node"
  description = "Absolute directory for the built template."
}

variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/debian-cd/13.5.0/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso"
  description = "Debian 13.5.0 netinst ISO. Override via `-var iso_url=H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso` for the local cache."
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
  description = "ISO checksum (literal sha256). Pins Debian 13.5.0 netinst."
}

variable "minio_version" {
  type        = string
  default     = "RELEASE.latest-stable"
  description = "MinIO server release tag (documentation/annotation only -- the default download URL tracks the stable channel). For a fully-pinned rebuild override minio_download_url with an archive URL (https://dl.min.io/server/minio/release/linux-amd64/archive/minio.RELEASE.<ts>)."
}

variable "minio_download_url" {
  type        = string
  default     = "https://dl.min.io/server/minio/release/linux-amd64/minio"
  description = "MinIO server binary URL (single Go binary, AGPL community build). Cache to H:/VMS/ISO/minio for an offline rebuild and override here. Pin via the archive/ path for byte-stable rebuilds."
}

variable "mc_download_url" {
  type        = string
  default     = "https://dl.min.io/client/mc/release/linux-amd64/mc"
  description = "MinIO client (mc) binary URL. Used by the smoke gate + operator playbooks (mb/admin/ping). Cache to H:/VMS/ISO/mc for an offline rebuild."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build-time vCPU (matches the minio spec, vms.yaml: 2 vCPU)."
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "Build-time RAM (MB). Default 2 GB per memory/feedback_prefer_less_memory.md (MinIO is light; the erasure/heal working set fits at lab data volumes). Production reverts to 8-16 GB."
}

variable "disk_gb" {
  type        = number
  default     = 20
  description = "OS disk size in GB (Debian + the MinIO/mc binaries are tiny; object data lives on the dedicated data disk). Growable VMDK only consumes what it writes."
}

variable "data_disk_gb" {
  type        = number
  default     = 100
  description = "Dedicated MinIO data disk in GB (the erasure-set drive at /mnt/minio/data, xfs label minio-data). Growable VMDK only consumes what it writes."
}

variable "ssh_username" {
  type    = string
  default = "nexusadmin"
}

variable "ssh_password" {
  type      = string
  default   = "nexus-packer-build-only"
  sensitive = true
}

variable "boot_wait" {
  type    = string
  default = "20s"
  # 20s (vs the analytics 15s) -- the build host also runs the 6 foundation VMs,
  # so the boot menu can be slow to appear; a too-short wait types the boot
  # command into nothing and the installer never starts.
}

variable "ssh_timeout" {
  type    = string
  default = "45m"
  # 45m (vs the analytics 30m) -- safety margin for a loaded build host. The
  # first 0.L.1 build timed out at exactly 30m waiting for SSH.
}
