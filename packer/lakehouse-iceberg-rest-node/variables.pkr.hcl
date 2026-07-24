/*
 * lakehouse-iceberg-rest-node -- Packer template variables (Phase 0.L.2)
 *
 * Per-engine template: JDK 21 + the Project Nessie quarkus-runner JAR (the
 * Iceberg REST catalog server).
 */

variable "vm_name" {
  type        = string
  default     = "lakehouse-iceberg-rest-node"
  description = "VM display name + output .vmx basename. Per-clone names (iceberg-rest-1/2) set by terraform/envs/lakehouse-iceberg/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/lakehouse-iceberg-rest-node"
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

variable "nessie_version" {
  type        = string
  default     = "0.107.5"
  description = "Project Nessie release version (latest stable as of 2026-04-21). Asset nessie-quarkus-<ver>-runner.jar."
}

variable "nessie_download_url" {
  type        = string
  default     = "https://github.com/projectnessie/nessie/releases/download/nessie-0.107.5/nessie-quarkus-0.107.5-runner.jar"
  description = "Nessie quarkus-runner uber-JAR URL (GitHub release). MUST match nessie_version. Also on Maven Central (org/projectnessie/nessie/nessie-quarkus). Cache to H:/VMS/ISO/ for an offline rebuild."
}

variable "jdk_package" {
  type        = string
  default     = "openjdk-21-jre-headless"
  description = "JDK package (Nessie/Quarkus needs Java 17+). Debian 13 ships openjdk-21. JAVA_HOME = /usr/lib/jvm/java-21-openjdk-amd64."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build-time vCPU (matches the iceberg-rest spec, vms.yaml: 2 vCPU)."
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "Build-time RAM (MB). Default 2 GB per memory/feedback_prefer_less_memory.md (Nessie is a light stateless REST server). Production reverts to 4 GB."
}

variable "disk_gb" {
  type        = number
  default     = 40
  description = "OS disk in GB (Nessie is stateless; metadata in PG, warehouse in MinIO). Growable VMDK only consumes what it writes."
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
