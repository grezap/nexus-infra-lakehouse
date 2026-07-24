/*
 * lakehouse-zookeeper-node -- Packer template variables (Phase 0.L.3)
 *
 * Per-engine template: JDK 21 + Apache ZooKeeper. The 3-node ensemble coordinates
 * Spark standalone master HA (recoveryMode=ZOOKEEPER).
 */

variable "vm_name" {
  type        = string
  default     = "lakehouse-zookeeper-node"
  description = "VM display name + output .vmx basename. Per-clone names (zookeeper-1/2/3) set by terraform/envs/lakehouse-spark/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/lakehouse-zookeeper-node"
  description = "Absolute directory for the built template."
}

variable "iso_url" {
  type    = string
  default = "H:/VMS/ISO/debian-13.5.0-amd64-netinst.iso"
  # Local ISO from the lab canon dir (H:/VMS/ISO/, project_iso_directory). The
  # upstream mirror rotates point releases off iso-cd/ into archive within months
  # (13.5.0 already 404s there as of 2026-07), so a remote default breaks replay;
  # the checksum below still pins integrity. For a fresh host, fetch the ISO into
  # H:/VMS/ISO/ once (or override -var iso_url=<url> against the archive mirror).
}

variable "iso_checksum" {
  type        = string
  default     = "sha256:95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a"
  description = "ISO checksum (literal sha256). Pins Debian 13.5.0 netinst."
}

variable "zookeeper_version" {
  type        = string
  default     = "3.9.3"
  description = "Apache ZooKeeper version (3.9 line; supports Java 17/21, logback logging)."
}

variable "zookeeper_download_url" {
  type        = string
  default     = "https://archive.apache.org/dist/zookeeper/zookeeper-3.9.3/apache-zookeeper-3.9.3-bin.tar.gz"
  description = "Apache ZooKeeper bin tarball (archive.apache.org keeps all releases). MUST match zookeeper_version. Cache to H:/VMS/ISO/ for an offline rebuild."
}

variable "jdk_package" {
  type        = string
  default     = "openjdk-21-jre-headless"
  description = "JDK package. ZooKeeper 3.9 supports Java 17/21. JAVA_HOME = /usr/lib/jvm/java-21-openjdk-amd64."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build-time vCPU (matches the zookeeper node spec, vms.yaml: 2 vCPU)."
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "Build-time RAM (MB). Default 2 GB per memory/feedback_prefer_less_memory.md (ZK holds only election metadata). Production reverts to 4 GB."
}

variable "disk_gb" {
  type        = number
  default     = 40
  description = "OS disk in GB (ZK snapshots/txnlogs are tiny for this workload). Growable VMDK only consumes what it writes."
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
}

variable "ssh_timeout" {
  type    = string
  default = "45m"
}
