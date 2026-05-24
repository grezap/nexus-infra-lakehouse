/*
 * lakehouse-spark-node -- Packer template variables (Phase 0.L.3)
 *
 * Per-engine template: JDK 21 + Apache Spark (bin-hadoop3) + the S3A connector
 * (hadoop-aws + aws-java-sdk-bundle, versions matched to Spark's bundled Hadoop)
 * + the Iceberg Spark runtime. One image serves both spark-master and
 * spark-worker roles.
 */

variable "vm_name" {
  type        = string
  default     = "lakehouse-spark-node"
  description = "VM display name + output .vmx basename. Per-clone names (spark-master-1/2, spark-worker-1/2/3) set by terraform/envs/lakehouse-spark/."
}

variable "output_directory" {
  type        = string
  default     = "H:/VMS/NexusPlatform/_templates/lakehouse-spark-node"
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

variable "spark_version" {
  type        = string
  default     = "3.5.3"
  description = "Apache Spark version (3.5 line: Scala 2.12, mature Iceberg + S3A support). bin-hadoop3 bundles Hadoop 3.3.4 client libs."
}

variable "spark_download_url" {
  type        = string
  default     = "https://archive.apache.org/dist/spark/spark-3.5.3/spark-3.5.3-bin-hadoop3.tgz"
  description = "Apache Spark bin-hadoop3 tarball (archive.apache.org keeps all releases). MUST match spark_version. Cache to H:/VMS/ISO/ for an offline rebuild."
}

variable "iceberg_version" {
  type        = string
  default     = "1.7.1"
  description = "Apache Iceberg version. Asset iceberg-spark-runtime-3.5_2.12-<ver>.jar (REST catalog client; talks to Nessie's Iceberg REST API)."
}

variable "iceberg_runtime_url" {
  type        = string
  default     = "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/1.7.1/iceberg-spark-runtime-3.5_2.12-1.7.1.jar"
  description = "Iceberg Spark 3.5 runtime uber-JAR (Maven Central). MUST match iceberg_version + the Spark 3.5/Scala 2.12 line."
}

variable "iceberg_aws_bundle_url" {
  type        = string
  default     = "https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/1.7.1/iceberg-aws-bundle-1.7.1.jar"
  description = "Iceberg AWS bundle (AWS SDK v2) -- required by S3FileIO, which Iceberg uses to write the s3:// table locations the Nessie REST catalog vends. MUST match iceberg_version."
}

variable "hadoop_aws_version" {
  type        = string
  default     = "3.3.4"
  description = "hadoop-aws version -- MUST match the Hadoop version bundled in Spark bin-hadoop3 (3.3.4 for Spark 3.5.x)."
}

variable "hadoop_aws_url" {
  type        = string
  default     = "https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar"
  description = "hadoop-aws JAR (the S3AFileSystem). MUST match the bundled Hadoop version or S3A class-loading breaks."
}

variable "aws_sdk_bundle_url" {
  type        = string
  default     = "https://repo1.maven.org/maven2/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar"
  description = "AWS Java SDK v1 bundle -- the exact version hadoop-aws 3.3.4 was compiled against (1.12.262). Mismatch = NoSuchMethodError at runtime."
}

variable "jdk_package" {
  type        = string
  default     = "openjdk-21-jre-headless"
  description = "JDK package. Spark 3.5 supports Java 17/21. JAVA_HOME = /usr/lib/jvm/java-21-openjdk-amd64."
}

variable "cpus" {
  type        = number
  default     = 2
  description = "Build-time vCPU (matches the spark node spec, vms.yaml: 2 vCPU)."
}

variable "memory_mb" {
  type        = number
  default     = 4096
  description = "Build-time RAM (MB). Default 4 GB per memory/feedback_prefer_less_memory.md (workers run executors). Production reverts to 8-16 GB."
}

variable "disk_gb" {
  type        = number
  default     = 40
  description = "OS disk in GB (Spark scratch in /tmp; warehouse + event logs in MinIO). Growable VMDK only consumes what it writes."
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
