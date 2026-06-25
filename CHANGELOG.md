# Changelog

All notable changes to `nexus-infra-lakehouse` are documented here. Format per
[Keep a Changelog](https://keepachangelog.com/); this repo is the NexusPlatform
lakehouse tier (`08-spark`), Phase 0.L.

## [Unreleased]

### Fixed / cold-rebuild (2026-06-25, for nexus-cli v0.8.4 LakehouseAdapter)
- **`vmrun_path` x86 → non-x86** in `terraform/envs/lakehouse-{minio,iceberg,spark}/variables.tf` + `terraform/modules/vm/variables.tf` — the default pointed at the deleted `C:/Program Files (x86)/...` path (the VMware-relocation trap); a from-zero clone failed on it. Now `C:/Program Files/VMware/VMware Workstation/vmrun.exe`.
- **Cold-rebuild-proven the Iceberg + Spark envs** (`lakehouse-iceberg.ps1` + `lakehouse-spark.ps1` destroy→apply→smoke; MinIO kept in place — reformatting its EC drives would wipe the cross-tier loki/tempo/harbor/starrocks buckets). Smoke 0.L.2 (28) + 0.L.3 (28) ALL PASSED; the Spark→Nessie→MinIO `s3a://warehouse` write round-trip (count=2) re-proved the cross-tier chain. This re-certed Nessie/iceberg-pg/Spark/ZooKeeper to the new Vault root (the v0.8.1-greenfield CA split) + re-seeded the iceberg-pg streaming standby.
- **3 transients chronicled:** (1) vmrun "Unknown error" on a single power_on after destroy → re-run apply (tainted retries clean); (2) post-destroy zombie VMs when the destroy ran with the pre-fix x86 path still in state (the destroy-provisioner's stop failed non-terminating → VMs left running + dirs intact) → recover by **in-guest `systemctl poweroff` BEFORE `destroy`** so the dirs unlock and Remove-Item cleans them; (3) **MinIO IAM key drift** — the v0.8.1 greenfield rotated KV `lakehouse/minio/app-secret-key` but the MinIO `nexus-lakehouse-app` user kept the old secret → fresh Nessie got S3 403 → data-preserving on-node `mc admin user add nexuslocal nexus-lakehouse-app <kv-secret>` re-sync (access key + policy + bucket data unchanged).

## [0.1.0] - 2026-05-26 — Phase 0.L lakehouse tier SEALED

Three sub-phases live-ratified + cold-rebuild-proven on the per-engine + per-cluster-state canon (all three sealed individually in May 2026):

- **0.L.1 MinIO** 4-node distributed erasure-coded object store (smoke 41/41 GREEN; 2 transients fixed in source; ADR-0033). The S3 backend every other lakehouse layer depends on, plus the 0.L.4 Harbor registry blob backend and the 0.L.5 StarRocks shared-data storage volume.
- **0.L.2 Iceberg REST catalog (Project Nessie ×2) + dedicated PostgreSQL 17 master-replica HA pair + keepalived VRRP VIP** (smoke 28/28 GREEN; 8 transients fixed in source; ADR-0034).
- **0.L.3 Apache Spark HA** (2 masters ZooKeeper-elected + 3 workers + dedicated 3-node Apache ZooKeeper ensemble) (smoke 28/28 GREEN; 10 transients fixed in source including the executor-RPC firewall gap; ADR-0035). End-to-end Spark → Iceberg → MinIO write path proven.
- **0.L.5 cross-tier (this release)**: dedicated MinIO tenant for the SR-shared-data cluster (`starrocks` bucket + `nexus-starrocks-app` service account + scoped `starrocks-tenant` policy with cross-bucket-deny proven; ADR-0037). The cluster itself lives in [`nexus-infra-analytics` v0.2.0](https://github.com/grezap/nexus-infra-analytics).

16 lakehouse VMs cold-rebuild proven (4 MinIO + 4 Iceberg + 8 Spark/ZK). All mTLS via per-host Vault PKI. Round-robin DNS front doors per ADR-0031. Documented in `docs/handbook.md` §0–§3.

### Added — Phase 0.L.5 cross-tier (2026-05-26) — MinIO `starrocks` tenant for the SR-shared-data cluster (ADR-0037)

`terraform/envs/lakehouse-minio/role-overlay-minio-starrocks-tenant.tf` — provisions the dedicated MinIO tenant for `nexus-infra-analytics`'s new shared-data cluster:

- **Bucket** `starrocks` (idempotent `mc mb --ignore-existing`) — holds the StarRocks storage volume's internal cloud-native tables at `s3://starrocks/`.
- **MinIO service account** `nexus-starrocks-app` (idempotent `mc admin user add`; access/secret keys read from Vault KV `nexus/analytics/starrocks-sd/s3-{access,secret}-key`, seeded by the security env's `role-overlay-vault-starrocks-sd-creds-seed.tf`).
- **Scoped policy** `starrocks-tenant`: `s3:ListBucket` + `s3:GetBucketLocation` on `arn:aws:s3:::starrocks` plus `s3:*` on `arn:aws:s3:::starrocks/*` — **no cross-bucket access** (tighter than the global `readwrite` policy reused by Harbor for `s3://harbor`; the explicit least-privilege choice in ADR-0037).
- **Negative-proof check**: the overlay tries to write to `s3://warehouse` as the new identity and FAILS on it (proving the policy is correctly scoped); then writes + reads + removes a probe object on `s3://starrocks` (proving normal use works). The whole bootstrap is gated by `SR_TENANT_OK`.

Runs on `minio-1` (reuses the existing `mc alias` configured by `role-overlay-minio-bucket-bootstrap`). Toggle: `enable_minio_starrocks_tenant` (default true). Variables added: `minio_starrocks_bucket`, `minio_starrocks_policy_name`, `kv_starrocks_s3_access_key_path`, `kv_starrocks_s3_secret_key_path`.

Applied 2026-05-26 — tenant bootstrap proven via cross-bucket-deny check; downstream `nexus-infra-analytics` SR-shared-data cluster SEALED same day (the storage volume `nexus_minio_starrocks` is live in this MinIO cluster's `starrocks` bucket).

### Added — Phase 0.L.1 (MinIO distributed erasure-coded object store)

- Repo scaffold on the per-cluster-state + per-engine-template canon: shared
  ansible roles (`nexus_identity`, `nexus_network`, `nexus_firewall`,
  `nexus_observability`, `lakehouse_firstboot`), reusable `terraform/modules/vm`
  clone driver, 5-job CI (`packer-validate.yml`).
- `lakehouse_firstboot` shared role — NIC discovery (MAC OUI byte-5), IP→role
  map for all 11 lakehouse nodes (MinIO .141–.144, Spark .140/.145/.146, Iceberg
  REST .147/.148, Iceberg PG .149/.150), VMnet10 backplane config, node-identity
  env, PG primary/replica derivation.
- `packer/lakehouse-minio-node` — Debian 13 + MinIO server + mc client; dedicated
  data VMDK formatted xfs (label `minio-data`, `/mnt/minio/data`);
  `nexus-minio.service` delivered DISABLED.
- `terraform/envs/lakehouse-minio` — 4-node MinIO cluster + 5 overlays:
  nftables-backplane, vault-agents, tls (`public.crt`/`private.key`/`CAs`),
  config (render `minio.conf` from Vault KV + start the erasure set), and
  bucket-bootstrap (warehouse/spark-events/lakehouse buckets + `nexus-lakehouse-app`
  service account + erasure-health + object round-trip exit gate).
- Operator wrapper `scripts/lakehouse-minio.ps1` + smoke gate `scripts/smoke-0.L.1.ps1`.
- Cross-tier overlays in `nexus-infra-vmware`: foundation
  (`role-overlay-gateway-lakehouse-{reservations,dns}.tf`) + security
  (`role-overlay-vault-pki-minio.tf`, `role-overlay-vault-agent-minio-{policies,approles}.tf`,
  `role-overlay-vault-minio-creds-seed.tf`).
- ADR-0033 (MinIO distributed EC object storage; supersedes ADR-0032's
  "MinIO deferred" note) in `nexus-platform-plan`.

### Added — Phase 0.L.2 (Iceberg REST catalog + dedicated PostgreSQL HA)

- `packer/lakehouse-iceberg-pg-node` — Debian 13 + PostgreSQL 17 (PGDG) +
  keepalived (deb13/trixie `libicu`/`libldap` bookworm fallback); `postgresql` +
  `keepalived` services delivered DISABLED.
- `packer/lakehouse-iceberg-rest-node` — Debian 13 + Temurin JDK 21 + Project
  Nessie 0.107.5 uber-jar at `/opt/nessie/nessie-quarkus-runner.jar` (`/opt/nessie`
  forced `0755` so the build user can post-install-check it);
  `nexus-nessie.service` delivered DISABLED.
- `terraform/envs/lakehouse-iceberg` — 2 PG + 2 Nessie REST nodes + 6 overlays:
  nftables-backplane, vault-agents, tls (per-role: PG `server.{crt,key}` owned by
  `postgres` with `iceberg-db.nexus.lab`+VIP SANs / REST `cert.pem`+`key.pem` with
  `iceberg.nexus.lab` round-robin SAN), pg-replication (primary conf.d/pg_hba/roles
  + `nessie` DB; replica `pg_basebackup -R` hot standby; keepalived VRRP VIP `.151`
  BACKUP+nopreempt with promote hook), nessie-config (JDBC2 named-`postgresql`
  datasource → VIP, S3 secret-URN creds → MinIO, Vault CA into JVM truststore),
  and catalog-bootstrap (Iceberg REST `/v1/config` + Nessie `/api/v2/config` +
  namespace round-trip exit gate).
- Operator wrapper `scripts/lakehouse-iceberg.ps1` + smoke gate
  `scripts/smoke-0.L.2.ps1` (28 checks).
- Cross-tier overlays in `nexus-infra-vmware`: foundation DNS/reservations extended
  (`iceberg.nexus.lab` → .147/.148 + `iceberg-db.nexus.lab` → VIP .151) + security
  (`role-overlay-vault-pki-iceberg.tf`,
  `role-overlay-vault-agent-iceberg-{policies,approles}.tf`,
  `role-overlay-vault-iceberg-creds-seed.tf`).
- ADR-0034 (Iceberg REST catalog — Project Nessie on a dedicated PostgreSQL
  master-replica HA pair) in `nexus-platform-plan`.
- Live-ratified + cold-rebuild-proven 2026-05-24 (`smoke-0.L.2.ps1` 28/28 GREEN);
  8 apply-time transients fixed in source (handbook §3.4).

### Added — Phase 0.L.3 (Apache Spark HA + ZooKeeper)

- `packer/lakehouse-spark-node` — Debian 13 + Temurin JDK 21 + Apache Spark 3.5.3
  (bin-hadoop3) + the S3A connector (`hadoop-aws` 3.3.4 + `aws-java-sdk-bundle`
  1.12.262) + Iceberg Spark runtime 1.7.1 + `iceberg-aws-bundle` 1.7.1 (AWS SDK v2
  for `S3FileIO`). Both `nexus-spark-master.service` + `nexus-spark-worker.service`
  delivered DISABLED.
- `packer/lakehouse-zookeeper-node` — Debian 13 + JDK 21 + Apache ZooKeeper 3.9.3;
  `nexus-zookeeper.service` delivered DISABLED.
- `lakehouse_firstboot` extended: spark-master-2 (.153), spark-worker-3 (.154),
  zookeeper-1/2/3 (.155-.157); emits `NEXUS_ZK_ID` for ZK nodes.
- `terraform/envs/lakehouse-spark` — 8 VMs (2 masters + 3 workers + 3 ZooKeeper) +
  overlays: nftables-backplane (+ Spark cluster-peer RPC accept for dynamic
  driver/blockManager ports), vault-agents (5 spark nodes), tls (`spark-server`
  PKI), zk-ensemble (zoo.cfg + myid; quorum), spark-config (recoveryMode=ZOOKEEPER,
  multi-master URL, driver.host pinned, in-memory session catalog, Nessie REST
  catalog warehouse-by-name + S3FileIO, authenticate + AES crypto), and
  cluster-bootstrap (HA election + 3 workers + `/spark` in ZK + Spark→Nessie→MinIO
  Iceberg write round-trip exit gate).
- Operator wrapper `scripts/lakehouse-spark.ps1` + smoke gate
  `scripts/smoke-0.L.3.ps1` (28 checks; `-IncludeChaos` master-failover).
- Cross-tier overlays in `nexus-infra-vmware`: foundation reservations/DNS extended
  (5 MACs `:AA`-`:AE` → `.153`/`.154`/`.155`/`.156`/`.157`; `spark-master.nexus.lab`
  → the 2 HA masters) + security (`role-overlay-vault-pki-spark.tf`,
  `role-overlay-vault-agent-spark-{policies,approles}.tf`,
  `role-overlay-vault-spark-creds-seed.tf`).
- ADR-0035 (Spark standalone HA — 2 masters + Apache ZooKeeper quorum; the one
  deliberate ZK exception) in `nexus-platform-plan`.
- Live-ratified + cold-rebuild-proven 2026-05-24 (`smoke-0.L.3.ps1` 28/28 GREEN);
  10 apply-time transients fixed in source (handbook §3.6), incl. the
  executor-RPC firewall gap and the driver.host round-robin trap.
